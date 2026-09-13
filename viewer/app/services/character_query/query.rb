# frozen_string_literal: true

module CharacterQuery
  # Executes a constraint stack and returns a shortlist.
  #
  # Two rules govern every database call here:
  #
  #  1. Property lookups always pass BOTH source and field, or are constrained
  #     by character_codepoint_id. The index is (source, field, value) plus
  #     (character_codepoint_id, field); an unconstrained field-only filter
  #     falls back to a full scan — measured at 14.7s against 1.1s for the
  #     equivalent indexed work.
  #  2. Sets are intersected smallest-first, so the expensive facets only ever
  #     run against an already-narrow candidate list.
  #
  # Dictionary joins are written as explicit SQL joins on table names rather
  # than through associations, so this does not depend on association naming in
  # the existing models.
  class Query
    # Page sizes offered by the form. There is deliberately no maximum result
    # count: a ceiling on how many characters exist for a constraint is a
    # ceiling on the work, and the whole point of the tool is to find every
    # one of them. `total` is always the true figure, CSV always exports the
    # whole set, and only how much of it one page renders is bounded — by the
    # reader's choice, including "all".
    # How variant forms are folded together. See #variant_groups.
    GROUPINGS = { "opencc" => :opencc, "moe" => :moe, "both" => :both }.freeze

    # How the reading side and the rime-book side are joined. See
    # #combine_with_rime_books.
    COMBINE_MODES = { "and" => :and, "or" => :or }.freeze

    PER_PAGE_CHOICES = [50, 100, 250, 500, 1_000].freeze
    DEFAULT_PER_PAGE = 100
    ALL = :all

    # Upper bound for an IDS prefix search. See #ids_condition.
    IDS_PREFIX_CEILING = "\u{10FFFF}"

    Result = Struct.new(
      :rows, :total, :primary_count, :steps, :coverage, :warnings,
      :page, :per_page, :page_count, :offset, :matched_systems,
      keyword_init: true
    )

    # constraints: [{ system:, slot:, tone: }]
    # dictionary_filters: { work_id:, tone:, rhyme_label:, small_rime: }
    # columns: property field names (ToolsController::ENRICHABLE_FIELD_OPTIONS keys)
    # dictionary_columns: [work_id, ...] for verbatim entry text
    def initialize(system:, slot: nil, tone: nil, homophone_of: nil, match_tone: false,
                   component: nil, ids_expression: nil,
                   constraints: [], dictionary_filters: {},
                   columns: [], dictionary_columns: [], radical: nil, total_strokes: nil,
                   common_only: false, group_variants: false, combine: nil,
                   page: 1, per_page: DEFAULT_PER_PAGE)
      @homophone_of = homophone_of.to_s.strip.presence
      @match_tone = ActiveModel::Type::Boolean.new.cast(match_tone)
      @component = component.to_s.strip.presence
      @ids_expression = normalise_ids(ids_expression)
      @grouping = grouping_mode(group_variants)
      @system = system.to_s
      @slot = slot.to_s
      @tone = tone.presence && tone.to_i
      @constraints = Array(constraints)
      @dictionary_filters = dictionary_filters || {}
      @columns = Array(columns)
      @dictionary_columns = Array(dictionary_columns).map(&:to_i).reject(&:zero?)
      @radical = radical.presence
      @total_strokes = total_strokes.presence && total_strokes.to_i
      @common_only = ActiveModel::Type::Boolean.new.cast(common_only)
      @combine = COMBINE_MODES.fetch(combine.to_s.downcase, :and)
      # Case-insensitive on purpose. The controller already folds case, but a
      # rake task or a console call passing "ALL" would otherwise fall through
      # to to_i, land on 1, and hand back one character per page without
      # saying anything was wrong.
      @per_page = per_page.to_s.casecmp?(ALL.to_s) ? ALL : [per_page.to_i, 1].max
      @page = [page.to_i, 1].max
      @steps = []
      @warnings = []
      # Every reading system that constrained this search, in the order it was
      # applied, with the slots it matched on. One "matched reading" column is
      # rendered per entry.
      @constraint_slots = []
    end

    def call
      return empty_result unless ReadingSystem.known?(@system)
      return no_criteria_result if no_criteria?

      ids = primary_ids
      primary_count = ids.size
      record_step(:primary, primary_count, system: @system, slot: @slot, tone: @tone,
                                          broadened: rare_readings?, homophone_of: @homophone_of)

      ids = apply_structure_filters(ids)
      ids = apply_secondary_systems(ids)
      ids = combine_with_rime_books(ids)
      ids = apply_graphic_filters(ids)
      ids = apply_rarity_filter(ids)

      rows, total = @grouping ? grouped_rows(ids) : flat_rows(ids)

      Result.new(
        rows: rows,
        total: total,
        primary_count: primary_count,
        steps: @steps,
        coverage: coverage_report,
        warnings: @warnings,
        page: @page,
        per_page: @per_page,
        page_count: page_count(total),
        offset: offset,
        matched_systems: @constraint_slots.map { |entry| entry[:system] }
      )
    end

    private

    def display_slot
      @tone ? "#{@slot}#{@tone}" : @slot
    end

    # -- paging ------------------------------------------------------------
    #
    # The whole id set is always computed; paging only decides which slice is
    # hydrated into rows. Hydration is the expensive part, so a page costs the
    # same whether it is page 1 of 40 or page 40 of 40.

    def offset
      return 0 if @per_page == ALL

      (@page - 1) * @per_page
    end

    def page_count(total)
      return 1 if @per_page == ALL || total.zero?

      (total.to_f / @per_page).ceil
    end

    def page_slice(collection)
      return collection if @per_page == ALL

      collection.drop(offset).first(@per_page)
    end

    # Rare readings are searched by default. "Everyday characters only" turns
    # them off rather than fighting them: kHanyuPinyin's extra readings belong
    # overwhelmingly to characters outside Unihan's core set, so running both
    # gathers readings and then discards the characters carrying them. Llinos
    # named this the paradox, and it is exactly that — the two controls cancel,
    # so there is one control.
    # Accepts the mode names, and still accepts the "1" the control used to
    # send as a checkbox, so a bookmarked query keeps working.
    def grouping_mode(value)
      raw = value.to_s.strip.downcase
      return nil if raw.empty? || %w[0 false off].include?(raw)
      return :opencc if %w[1 true on].include?(raw)

      GROUPINGS[raw]
    end

    def rare_readings?
      !@common_only
    end

    def reading_systems_for(system)
      broad = ReadingSystem.definition(system)&.dig(:broad)
      return [system] if broad.blank? || !rare_readings?

      [system, broad]
    end

    # IDS specs arrive from the shared builder, which writes "?" for a slot the
    # reader has left open. Normalising through Ids::Parser keeps this in step
    # with how normalized_expression was written at import; the builder's own
    # search does the same.
    def normalise_ids(expression)
      raw = expression.to_s.strip
      return nil if raw.empty?
      return nil if raw.delete("?").strip.empty? # "?" alone constrains nothing

      normalised = (Ids::Parser.normalize(raw) rescue raw)
      normalised.to_s.strip.presence
    end

    # At least one of syllable, character, component or IDS must be given.
    # Without one the query has nothing to start from, and returning the whole
    # repertoire would be neither useful nor kind to the database.
    # A rime book carries no syllable to type, so its facets ARE its criteria.
    # Without this, choosing 廣韻 and a tone would be reported as "no criteria
    # given" — technically true of the syllable box, and useless.
    def no_criteria?
      @slot.blank? && @homophone_of.blank? && @component.blank? &&
        @ids_expression.blank? && !rime_book_primary? && !rime_book_facets?
    end

    def rime_book_primary?
      ReadingSystem.definition(@system)&.fetch(:kind, nil) == :rime_book
    end

    # A book named in the panel, with at least one facet filled. On its own
    # that is a complete question — "which characters does 廣韻 file under
    # 上聲" — and reporting it as "no criteria given" because the syllable box
    # was empty would be a lie about what the reader asked.
    def rime_book_facets?
      filters = @dictionary_filters.symbolize_keys
      filters[:work_id].to_i.positive? &&
        filters.except(:work_id).values.any?(&:present?)
    end

    def no_criteria_result
      @warnings << { code: :no_criteria }
      Result.new(rows: [], total: 0, primary_count: 0, page: 1, per_page: @per_page, page_count: 1, offset: 0,
                 matched_systems: [], steps: @steps, coverage: {}, warnings: @warnings)
    end

    def empty_result
      @warnings << { code: :unknown_system, value: @system }
      Result.new(rows: [], total: 0, primary_count: 0, page: 1, per_page: @per_page, page_count: 1, offset: 0,
                 matched_systems: [], steps: @steps, coverage: {}, warnings: @warnings)
    end

    def primary_ids
      return rime_book_primary_ids if rime_book_primary?
      return homophone_ids if @homophone_of.present?
      return rime_facet_primary_ids if reading_side_empty? && rime_book_facets?
      return structure_primary_ids if @slot.blank?

      slot_primary_ids
    end

    def reading_side_empty?
      @slot.blank? && @component.blank? && @ids_expression.blank?
    end

    # The panel named a book and gave it a facet, and nothing else was asked.
    # Start from that whole book and let the ordinary dictionary step narrow
    # it, so this behaves exactly as if the book had been chosen as the
    # source — which is what the reader meant.
    def rime_facet_primary_ids
      work_id = @dictionary_filters.symbolize_keys[:work_id].to_i
      ids = work_character_ids(work_id)
      record_constraint(RimeBooks.id_for(work_id), nil)
      ids
    end

    # The whole of a rime book, as the starting set, so its own facets can
    # narrow it below.
    #
    # This is what makes a book pickable the way a locality is. It is NOT a
    # reading system: there is no romanisation to type, because a rime book
    # spells with 反切 and every romanisation of it — Baxter, Pulleyblank,
    # Karlgren — is somebody's reading of that spelling and belongs to them,
    # not to the book. So the book contributes the characters it covers, and
    # the facets say which of them.
    #
    # The facets are forced onto this book whatever the panel sent, so the
    # source that was picked is the source that is applied.
    def rime_book_primary_ids
      work_id = ReadingSystem.definition(@system)[:work_id]
      filters = @dictionary_filters.symbolize_keys

      # Two ways to name a book reach here: chosen as the source above, or
      # chosen in the rime-book panel. If they disagree, say so instead of
      # picking one — quietly applying 集韻's categories to a 廣韻 search is
      # the exact substitution this work exists to stop.
      chosen = filters[:work_id].to_i
      if chosen.positive? && chosen != work_id
        @warnings << { code: :rime_book_conflict, system: @system, other: chosen }
      end

      @dictionary_filters = filters.merge(work_id: work_id)

      ids = work_character_ids(work_id)
      record_constraint(@system, nil)
      ids
    end

    # Every character one book covers.
    def work_character_ids(work_id)
      DictionaryEntryCharacter
        .joins("INNER JOIN dictionary_entries de ON de.id = dictionary_entry_characters.dictionary_entry_id")
        .where("de.dictionary_work_id = ?", work_id)
        .distinct
        .pluck(Arel.sql("dictionary_entry_characters.character_codepoint_id"))
    end

    # Component or IDS as the starting point, when no reading was given.
    # The component lookup is indexed and quick; the IDS lookup constrains
    # `system` so its (system, normalized_expression) index is usable — without
    # that it degrades from 0.02s to a scan.
    def structure_primary_ids
      return component_ids if @component.present?

      ids_expression_ids
    end

    def slot_primary_ids
      tone = @tone

      if tone && ReadingSystem.toneless?(@system)
        # Better to say so than to silently return the whole slot.
        @warnings << { code: :tone_on_toneless_system, value: @system }
        tone = nil
      end

      record_constraint(@system, [[@slot, tone]])
      ids = reading_systems_for(@system).inject([]) { |acc, system| acc | slot_ids(system, @slot, tone) }

      # "Nothing matched" and "this system does not have that syllable" are
      # different answers, and only the second tells the reader what to do
      # next. Shanghai has no zɿ — it writes the voiced onset zɦ — and the
      # whole query looked broken until it said so.
      if ids.empty?
        @warnings << { code: :slot_not_in_system, value: display_slot, system: @system,
                       suggestions: SlotIndex.nearest_slots(@system, @slot) }
      end

      ids
    end

    # Homophone seeker: take a character, read its own readings in the chosen
    # system, and return everything sharing them. "Match tone" decides whether
    # a shared syllable is enough or the tone has to agree too.
    #
    # Reads the rare field alongside the common one on the same rule as a
    # syllable search, so 一 finds its company through every reading it is
    # recorded with, not only its headline one.
    def homophone_ids
      return [] if ReadingSystem.definition(@system).nil?

      record = homophone_record

      if record.nil?
        @warnings << { code: :character_not_found, value: @homophone_of }
        return []
      end

      systems = reading_systems_for(@system)
      pairs = systems.flat_map { |system| readings_of(record, system) }
                     .map { |reading| ReadingSystem.split(reading, @system) }
                     .reject { |slot, _| slot.blank? }.uniq

      if pairs.empty?
        @warnings << { code: :no_readings_for_character, value: @homophone_of }
        return []
      end

      @slot = pairs.first.first
      @tone = @match_tone ? pairs.first.last : nil
      record_constraint(@system, pairs.map { |slot, reading_tone| [slot, @match_tone ? reading_tone : nil] })

      pairs.flat_map do |slot, reading_tone|
        systems.flat_map { |system| slot_ids(system, slot, @match_tone ? reading_tone : nil) }
      end.uniq
    end

    def readings_of(record, system)
      definition = ReadingSystem.definition(system)
      return [] if definition.nil?

      values =
        if definition[:table].present?
          SlotIndex::TABLE_MODELS.fetch(definition[:table]).constantize
                  .where(character_codepoint_id: record.id).pluck(definition[:column])
        else
          CharacterProperty.where(character_codepoint_id: record.id,
                                  source: definition[:source], field: definition[:field]).pluck(:value)
        end

      values.flat_map { |value| ReadingSystem.readings_in(value, system) }
    end

    # Graphic structure. Applied as post-filters when a reading already
    # narrowed the set, so both are constrained by character_codepoint_id.
    def apply_structure_filters(ids)
      return ids if ids.empty?

      if @component.present? && @slot.present?
        ids &= component_ids(ids)
        record_step(:component, ids.size, component: @component)
      end

      if @ids_expression.present? && (@slot.present? || @component.present?)
        ids &= ids_expression_ids(ids)
        record_step(:ids, ids.size, expression: @ids_expression)
      end

      ids
    end

    def component_ids(scope_ids = nil)
      relation = CharacterStructureComponent
                 .joins("INNER JOIN character_structures cs ON cs.id = character_structure_components.character_structure_id")
                 .where(component: @component)
      relation = relation.where("cs.character_codepoint_id IN (?)", scope_ids) if scope_ids.present?
      relation.distinct.pluck(Arel.sql("cs.character_codepoint_id"))
    end

    def ids_expression_ids(scope_ids = nil)
      condition = ids_condition
      return Array(scope_ids) if condition.nil?

      relation = CharacterStructure.where(system: "ids").where(*condition)
      relation = relation.where(character_codepoint_id: scope_ids) if scope_ids.present?
      relation.distinct.pluck(:character_codepoint_id)
    end

    # The shared IDS builder writes "?" for a slot the reader left open, so an
    # expression arrives in one of three shapes. Each gets the cheapest form
    # that is still exact.
    #
    #   ⿰木目   no open slot        equality
    #   ⿰木?    open slots at the end   prefix range
    #   ⿰?木    an open slot inside     GLOB
    #
    # Why a range and not LIKE for the prefix case: LIKE cannot use the
    # (system, normalized_expression) index, because SQLite's LIKE is
    # case-insensitive for ASCII while the column collates BINARY. The index
    # still matched on `system` — but all 355,698 rows carry system = "ids",
    # so it degraded to a LIKE test over the whole table. Measured: 0.753s
    # against 0.005s for the range.
    #
    # The ceiling is U+10FFFF, not U+FFFF. Under BINARY collation UTF-8 sorts
    # in code point order, so a U+FFFF ceiling silently drops every expression
    # whose next character is astral — ⿰木𫈼, ⿰木𠘻 and 203 others for ⿰木
    # alone, which is exactly the rare repertoire a structure search came for.
    #
    # GLOB rather than LIKE for the inner case for the same index reason: GLOB
    # is byte-exact, so SQLite derives a prefix range from it ("⿰" here) and
    # seeks. "?" becomes "*" — any complete subtree, not a single character —
    # because a reader drawing ⿰?木 means "anything on the left", and what
    # goes there is often itself compound, as in ⿰⿱艹早木.
    def ids_condition
      pattern = @ids_expression

      unless pattern.include?("?")
        # A COMPLETE expression is an exact match. An INCOMPLETE one is a
        # prefix.
        #
        # ⿰ is binary: it needs two operands, and ⿰木 supplies one. No stored
        # normalized_expression is ever incomplete, so matching ⿰木 exactly
        # can only return nothing — a query that is silently guaranteed to
        # fail, which is the worst kind. What the reader means by ⿰木 is
        # plainly "left-to-right, 木 on the left, anything on the right",
        # which is the same question ⿰木? asks through the builder.
        return ["normalized_expression = ?", pattern] if Ids::Parser.complete?(pattern)

        return ["normalized_expression >= ? AND normalized_expression < ?",
                pattern, "#{pattern}#{IDS_PREFIX_CEILING}"]
      end

      head = pattern[/\A[^?]*/].to_s

      # Every "?" is trailing when nothing but them follows the head.
      if pattern.delete("?") == head
        return nil if head.empty?

        return ["normalized_expression >= ? AND normalized_expression < ?",
                head, "#{head}#{IDS_PREFIX_CEILING}"]
      end

      # GLOB reads "*", "[" and "]" as syntax. IDS carries none of them, but a
      # pasted expression might, and a stray bracket would silently change what
      # matches rather than fail. Fall back to the prefix in that case.
      return (head.empty? ? nil : ["normalized_expression >= ? AND normalized_expression < ?",
                                   head, "#{head}#{IDS_PREFIX_CEILING}"]) if pattern.match?(/[*\[\]]/)

      ["normalized_expression GLOB ?", pattern.tr("?", "*")]
    end

    def slot_ids(system, slot, tone)
      return [] if system.blank?

      SlotIndex.codepoint_ids(system_id: system, slot: slot, tone: tone)
    rescue SlotIndex::Unsupported => error
      @warnings << { code: :unsupported_system, value: error.message }
      []
    end

    # A second reading system does one of two jobs, decided by whether its
    # syllable box is filled.
    #
    #   FILTER  — a syllable is given, or a character is given above and the
    #             syllable left blank: the set is narrowed to characters that
    #             also carry that reading there.
    #
    #   DISPLAY — nothing is given and there is no character to read one off:
    #             the system constrains nothing and simply contributes its
    #             column, so a Mandarin search can show each result's Middle
    #             Chinese beside it.
    #
    # The display case used to be dropped on the floor. It is the more common
    # thing to want: "every character read dàng, and what each is in Middle
    # Chinese" is a question about one set with two descriptions, not an
    # intersection of two sets.
    #
    # Reading a blank syllable off a given character is what makes comparing
    # 是 across Beijing and Shanghai possible without knowing that Xiaoxuetang
    # writes the Shanghai onset zɦ rather than z.
    def apply_secondary_systems(ids)
      @constraints.each do |constraint|
        system = constraint[:system].to_s
        next if system.blank?

        typed = constraint[:slot].to_s

        if typed.blank? && @homophone_of.blank?
          # Display only. Recorded with no slots, which is what tells the
          # renderer to show every reading rather than only matching ones.
          record_constraint(system, nil)
          record_step(:secondary_display, ids.size, system: system)
          next
        end

        break if ids.empty?

        from_character = typed.blank?
        slots =
          if from_character
            slots_from_character(system)
          else
            [[typed, constraint[:tone].presence && constraint[:tone].to_i]]
          end

        if slots.empty?
          @warnings << { code: :no_reading_in_system, value: @homophone_of, system: system }
          next
        end

        other = slots.flat_map { |slot, tone| slot_ids(system, slot, tone) }.uniq
        next if other.empty? && @warnings.any? { |w| w[:code] == :unsupported_system }

        # A typed syllable that is not in the system's inventory at all is a
        # different failure from a syllable that exists but shares nothing —
        # and the first is usually a spelling difference, not a mistake.
        if other.empty? && !from_character
          @warnings << { code: :slot_not_in_system, value: typed, system: system,
                         suggestions: SlotIndex.nearest_slots(system, typed) }
        end

        record_constraint(system, slots)
        ids &= other
        record_step(:secondary, ids.size, system: system,
                                          slot: slots.map(&:first).uniq.join(" / "),
                                          tone: slots.first&.last,
                                          from_character: from_character ? @homophone_of : nil)
      end

      ids
    end

    # The given character's own slots in another system.
    def slots_from_character(system)
      return [] if @homophone_of.blank?

      record = homophone_record
      return [] if record.nil?

      reading_systems_for(system)
        .flat_map { |id| readings_of(record, id) }
        .map { |reading| ReadingSystem.split(reading, system) }
        .reject { |slot, _| slot.blank? }
        .map { |slot, tone| [slot, @match_tone ? tone : nil] }
        .uniq
    end

    def homophone_record
      return @homophone_record if defined?(@homophone_record)

      codepoint = @homophone_of.to_s.codepoints.first
      @homophone_record = codepoint && CharacterCodepoint.find_by(codepoint: codepoint)
    end

    # A rime book is a source, and a tone or rhyme category only means
    # anything inside the book that assigned it.
    #
    # 上聲 is not one category. 廣韻 files 3,713 characters under it, 集韻
    # 5,960, 五音集韻 6,273, 切韻 2,180, 洪武正韻 2,603 — five different
    # editorial judgements, from 601 to 1375, by five different compilers.
    # 韻目 is worse: 麻 is a section heading in six of these books and means a
    # different rime in each.
    #
    # So a facet with no book behind it is a misattribution, and this method
    # refuses to guess. It returns nothing and says why, because a filter that
    # silently declines to apply hands back a result that looks narrowed and
    # is not.
    #
    # Every facet below is reached through de.dictionary_work_id. ds arrives
    # through de.dictionary_section_id, so scoping de scopes the sections too
    # and no second guard is needed.
    def apply_dictionary_filters(ids)
      return ids if ids.empty?

      matched = dictionary_match_ids(ids)
      return ids if matched.nil?

      ids &= matched
      record_step(:dictionary, ids.size, **dictionary_step_detail)
      ids
    end

    # AND joins the reading side to the rime-book side; OR unions them.
    #
    # OR is worth having because the two sides cover very different amounts of
    # the language. Baxter & Sagart reconstruct roughly 4,000 characters;
    # 廣韻 files 16,079. Under AND, asking for a Baxter syllable AND a 廣韻
    # tone can only ever return characters Baxter happens to have — the rime
    # book cannot add anything, only take away. Under OR it can, which is the
    # difference between "what do both say" and "what does either say".
    #
    # The union is taken BEFORE the graphic and rarity filters, so a radical
    # or stroke count still narrows the whole answer. Those are facts about
    # the written form and belong to neither side.
    #
    # When a rime book is itself the source, there are not two sides to join:
    # the facets already belong to it, so the mode is ignored.
    def combine_with_rime_books(ids)
      return apply_dictionary_filters(ids) if @combine == :and || rime_book_primary?

      matched = dictionary_match_ids(nil)
      return ids if matched.nil?

      union = (ids | matched)
      record_step(:dictionary_or, union.size,
                  added: (matched - ids).size, **dictionary_step_detail)
      union
    end

    # The characters one rime book's facets select.
    #
    # `scope_ids` narrows the query to a candidate set; nil asks the question
    # of the whole book, which is what OR needs. Returns nil when there is
    # nothing to ask — no facets given — so a caller can tell "no constraint"
    # apart from "constraint matched nothing".
    def dictionary_match_ids(scope_ids)
      filters = @dictionary_filters.symbolize_keys
      facets = filters.except(:work_id)
      return nil if facets.values.all?(&:blank?)

      work_id = filters[:work_id].to_i
      if work_id.zero?
        @warnings << { code: :rime_book_not_chosen, facets: facets.compact_blank.keys }
        record_step(:dictionary, 0, skipped: :no_rime_book)
        return []
      end

      scope = scope_ids ? dictionary_scope(scope_ids) : dictionary_scope_all
      scope = scope.where("de.dictionary_work_id = ?", work_id)
      scope = scope.where("ds.tone = ?", filters[:tone]) if filters[:tone].present?
      scope = scope.where("ds.rhyme_label = ?", filters[:rhyme_label]) if filters[:rhyme_label].present?
      scope = scope.where("de.small_rime_number = ?", filters[:small_rime].to_i) if filters[:small_rime].present?
      scope = scope.where(fanqie_condition(filters[:fanqie])) if filters[:fanqie].present?

      scope.distinct.pluck(Arel.sql("dictionary_entry_characters.character_codepoint_id"))
    end

    def dictionary_step_detail
      filters = @dictionary_filters.symbolize_keys
      { work_id: filters[:work_id].to_i }.merge(filters.except(:work_id).compact_blank)
    end

    # The 反切 itself, as the book spells it. Matched on the stored value and
    # on the value minus its trailing 切/反, so 徳紅 and 徳紅切 both find 東.
    def fanqie_condition(raw)
      value = raw.to_s.strip
      bare = value.sub(/[切反]\z/, "")
      ["dictionary_entry_characters.dictionary_entry_id IN (
          SELECT dr.dictionary_entry_id FROM dictionary_readings dr
          WHERE dr.kind = 'fanqie' AND (dr.value = ? OR dr.value = ? OR dr.value = ?)
        )", value, bare, "#{bare}切"]
    end

    # The same joins with no candidate set in front of them. Only OR uses
    # this, because only OR asks the book a question that does not start from
    # the reading side's answer.
    def dictionary_scope_all
      DictionaryEntryCharacter
        .joins("INNER JOIN dictionary_entries de ON de.id = dictionary_entry_characters.dictionary_entry_id")
        .joins("INNER JOIN dictionary_works dw_work ON dw_work.id = de.dictionary_work_id")
        .joins("LEFT JOIN dictionary_sections ds ON ds.id = de.dictionary_section_id")
    end

    def dictionary_scope(ids)
      DictionaryEntryCharacter
        .where(character_codepoint_id: ids)
        .joins("INNER JOIN dictionary_entries de ON de.id = dictionary_entry_characters.dictionary_entry_id")
        .joins("INNER JOIN dictionary_works dw_work ON dw_work.id = de.dictionary_work_id")
        .joins("LEFT JOIN dictionary_sections ds ON ds.id = de.dictionary_section_id")
    end

    def apply_graphic_filters(ids)
      return ids if ids.empty?
      return ids if @radical.blank? && @total_strokes.nil?

      if @total_strokes
        matched = CharacterProperty
                  .where(character_codepoint_id: ids,
                         source: "Unihan_IRGSources", field: "kTotalStrokes")
                  .pluck(:character_codepoint_id, :value)
                  .select { |_, value| value.to_s.split.map(&:to_i).include?(@total_strokes) }
                  .map(&:first)
        ids &= matched
        record_step(:total_strokes, ids.size, strokes: @total_strokes)
      end

      if @radical.present?
        matched = CharacterProperty
                  .where(character_codepoint_id: ids,
                         source: "Unihan_IRGSources", field: "kRSUnicode")
                  .pluck(:character_codepoint_id, :value)
                  .select { |_, value| value.to_s.split.any? { |rs| rs.split(".").first.to_s.delete("'") == @radical.to_s } }
                  .map(&:first)
        ids &= matched
        record_step(:radical, ids.size, radical: @radical)
      end

      ids
    end

    def apply_rarity_filter(ids)
      return ids unless @common_only
      return ids if ids.empty?

      matched = CharacterProperty
                .where(character_codepoint_id: ids,
                       source: "Unihan_DictionaryLikeData", field: "kUnihanCore2020")
                .pluck(:character_codepoint_id)
      ids &= matched
      record_step(:common_only, ids.size, field: "kUnihanCore2020")
      ids
    end

    # -- grouping ----------------------------------------------------------
    #
    # Variant forms of one character otherwise fill a result set with two or
    # three spellings of the same word. Grouping folds them into one row.
    #
    # Two sources, independently selectable, because they answer different
    # questions:
    #
    #   :opencc  script normalisation — 当 with 當, 汉 with 漢. Narrow and
    #            mechanical: the same word written in a different script.
    #
    #   :moe     the Taiwan Ministry of Education 異體字字典, already imported
    #            as variant_mappings: 58,483 mappings over 13,016 base
    #            characters. Orthographic variance proper — 蕩 with 蘯 and 簜,
    #            and 112 recorded forms of 龜. Broader, and editorial: it also
    #            records 壹 as a variant of 一, which is a different word for
    #            most purposes. That breadth is the reason it is a choice
    #            rather than the default.
    #
    #   :both    the transitive closure of the two. If MOE joins A to B and
    #            OpenCC joins B to C, all three are one group — which is why
    #            this is union-find rather than grouping on a key. A key
    #            cannot express two overlapping relations at once.
    #
    # Nothing is discarded. Every member keeps its own readings, glosses and
    # quotations, and the table lists them as rows under the head.
    def flat_rows(ids)
      page = page_slice(ids)
      [hydrate(page).map { |row| row.merge(variants: []) }, ids.size]
    end

    def grouped_rows(ids)
      groups = variant_groups(ids)
      record_step(:group_variants, groups.size, method: @grouping.to_s)

      page = page_slice(groups)
      hydrated = hydrate(page.flatten).index_by { |row| row[:codepoint_id] }

      rows = page.filter_map do |members|
        head = hydrated[members.first]
        next if head.nil?

        head.merge(variants: members.drop(1).filter_map { |id| hydrated[id] })
      end

      [rows, groups.size]
    end

    def variant_groups(ids)
      return [] if ids.empty?

      codepoint_by_id = CharacterCodepoint.where(id: ids).pluck(:id, :codepoint).to_h
      parent = {}
      canonical = Set.new

      union_by_script(ids, codepoint_by_id, parent, canonical) if %i[opencc both].include?(@grouping)
      union_by_moe(ids, codepoint_by_id, parent, canonical) if %i[moe both].include?(@grouping)

      grouped = ids.group_by { |id| find_root(parent, id) }

      # The orthodox form heads its group when one is present — OpenCC's
      # traditional form, or MOE's 正字 — and otherwise the lowest codepoint,
      # so the order is stable between requests either way.
      grouped.values.map do |members|
        members.sort_by { |id| [canonical.include?(id) ? 0 : 1, codepoint_by_id[id].to_i] }
      end
    end

    # Union-find over character ids, with a pseudo-node for each MOE base so
    # that two variants of an absent orthodox form still meet. Path-compressed;
    # the sets here are a few thousand members at most.
    def find_root(parent, node)
      root = node
      root = parent[root] while parent[root] && parent[root] != root

      while parent[node] && parent[node] != root
        parent[node], node = root, parent[node]
      end

      root
    end

    def union(parent, left, right)
      left_root = find_root(parent, left)
      right_root = find_root(parent, right)
      return if left_root == right_root

      parent[left_root] = right_root
    end

    def union_by_script(ids, codepoint_by_id, parent, canonical)
      chars = ids.map { |id| character_for(codepoint_by_id[id]) }
      keys = canonical_forms(chars)

      by_key = {}
      ids.each_with_index do |id, index|
        canonical << id if chars[index] == keys[index]
        first = (by_key[keys[index]] ||= id)
        union(parent, id, first)
      end
    end

    # One query per direction, both on indexed columns. The pseudo-node is
    # what makes 蘯 and 簜 group when 蕩 itself did not match the reading.
    def union_by_moe(ids, codepoint_by_id, parent, canonical)
      codepoints = codepoint_by_id.values.compact.uniq
      return if codepoints.empty?

      ids_by_codepoint = ids.group_by { |id| codepoint_by_id[id] }
      bases = VariantMapping.where(variant_codepoint: codepoints)
                            .pluck(:variant_codepoint, :base_codepoint)

      bases.each do |variant_codepoint, base_codepoint|
        next if base_codepoint.blank?

        Array(ids_by_codepoint[variant_codepoint]).each { |id| union(parent, id, "moe:#{base_codepoint}") }
      end

      # A character that is itself an orthodox form joins its own family and
      # heads it.
      VariantMapping.where(base_codepoint: codepoints).distinct.pluck(:base_codepoint).each do |base_codepoint|
        Array(ids_by_codepoint[base_codepoint]).each do |id|
          canonical << id
          union(parent, id, "moe:#{base_codepoint}")
        end
      end
    rescue StandardError => error
      @warnings << { code: :variant_grouping_unavailable, value: error.class.name }
    end

    # ONE OpenCC call for the whole set, not one per character.
    # CharacterStandards#opencc_convert opens and closes an OpenCC::Converter
    # on every call, so per-character conversion would open thousands of them.
    #
    # Newline-delimited because OpenCC's s2t config includes phrase rules
    # (STPhrases), which could otherwise apply across adjacent characters and
    # misalign the output. If the line count comes back wrong the conversion is
    # discarded entirely rather than risk mis-grouping.
    def canonical_forms(chars)
      return chars if chars.empty?

      converted = CharacterStandards.traditional(chars.join("\n")).to_s.split("\n", -1)
      return chars unless converted.size == chars.size

      converted.each_with_index.map { |value, index| value.presence || chars[index] }
    rescue StandardError => error
      @warnings << { code: :variant_grouping_unavailable, value: error.class.name }
      chars
    end

    def character_for(codepoint)
      return "" if codepoint.nil?

      [codepoint.to_i].pack("U")
    rescue StandardError
      ""
    end

    # -- output ------------------------------------------------------------

    def hydrate(ids)
      return [] if ids.empty?

      codepoints = CharacterCodepoint.where(id: ids).pluck(:id, :codepoint, :chr).to_h { |id, cp, chr| [id, { codepoint: cp, chr: chr }] }
      property_fields = (@columns + system_fields).uniq
      properties = property_rows(ids, property_fields)
      entries = @dictionary_columns.any? ? dictionary_entry_rows(ids) : {}
      rime_hits = rime_book_hits(ids)

      ids.map do |id|
        base = codepoints[id] || {}
        row = {
          codepoint_id: id,
          codepoint: base[:codepoint],
          char: base[:chr].presence || (base[:codepoint] && [base[:codepoint]].pack("U")),
          properties: properties[id] || {},
          dictionary_entries: entries[id] || []
        }
        row.merge(matched: matched_readings(row[:properties], rime_hits, id))
      end
    end

    # What each constrained rime book actually says about these characters:
    # its own 反切, its own 韻目, its own 聲調, attributed to it.
    #
    # A rime book has no romanisation to put in a reading column, and putting
    # someone else's there is the misattribution this all exists to stop. The
    # 反切 is the book's own datum, so that is what the column shows.
    #
    # One query per constrained book over the page's ids, not per row.
    def rime_book_hits(ids)
      books = @constraint_slots.map { |entry| entry[:system] }
                               .select { |id| ReadingSystem.rime_book?(id) }.uniq
      return {} if books.empty? || ids.empty?

      books.to_h do |system|
        work_id = ReadingSystem.definition(system)[:work_id]
        [system, rime_book_rows(ids, work_id)]
      end
    end

    def rime_book_rows(ids, work_id)
      rows = DictionaryEntryCharacter
             .where(character_codepoint_id: ids)
             .joins("INNER JOIN dictionary_entries de ON de.id = dictionary_entry_characters.dictionary_entry_id")
             .joins("LEFT JOIN dictionary_sections ds ON ds.id = de.dictionary_section_id")
             .joins("LEFT JOIN dictionary_readings dr ON dr.dictionary_entry_id = de.id AND dr.kind = 'fanqie'")
             .where("de.dictionary_work_id = ?", work_id)
             .pluck(Arel.sql(<<~COLUMNS))
               dictionary_entry_characters.character_codepoint_id,
               dr.value, ds.tone, ds.rhyme_label, de.small_rime_number,
               de.dictionary_section_id
             COLUMNS

      heads = small_rime_fanqie(work_id, rows.map(&:last).compact.uniq)

      rows.each_with_object({}) do |(ccid, fanqie, tone, rhyme, small_rime, section_id), acc|
        # A 反切 heads its 小韻 and is not repeated for the rest of the group.
        # 廣韻 spells 東 徳紅切 and then lists 菄 鶇 䍶 涷 under it, each with no
        # spelling of its own, because being in that 小韻 IS the statement that
        # they are spelled the same way.
        #
        # So the group's spelling is shown for every member, and the ones that
        # inherited it are marked, because "the book prints this here" and "the
        # book puts this character in a group headed by it" are different
        # claims and the reader should be able to tell them apart.
        inherited = fanqie.blank? && heads[[section_id, small_rime]].present?
        spelling = fanqie.presence || heads[[section_id, small_rime]]

        label = [
          spelling && (inherited ? "(#{spelling})" : spelling),
          [tone, rhyme].compact_blank.join,
          small_rime && "小韻#{small_rime}"
        ].compact_blank.join(" ")
        next if label.empty?

        (acc[ccid] ||= []) << label
      end.transform_values { |list| list.uniq.first(4) }
    end

    # (section, 小韻) => the 反切 that heads it.
    #
    # Scoped to the sections the page actually touches, not the whole book.
    # 廣韻 has 3,312 of these groups and pulling all of them cost 4.2s cold;
    # a page of results normally sits in a handful of rhymes, and asking for
    # those took milliseconds. The work id stays in the WHERE clause even
    # though the section ids already imply it, so this can never reach across
    # books by way of an id collision.
    def small_rime_fanqie(work_id, section_ids)
      return {} if section_ids.empty?

      DictionaryReading
        .joins("INNER JOIN dictionary_entries de ON de.id = dictionary_readings.dictionary_entry_id")
        .where(kind: "fanqie")
        .where("de.dictionary_work_id = ? AND de.dictionary_section_id IN (?)", work_id, section_ids)
        .pluck(Arel.sql("de.dictionary_section_id, de.small_rime_number, dictionary_readings.value"))
        .each_with_object({}) do |(section_id, small_rime, value), acc|
          acc[[section_id, small_rime]] ||= value
        end
    end

    # Which reading actually put this character in the set, and which field it
    # came from — one group per constrained reading system, in the order the
    # constraints were applied.
    #
    # Without this a result is a bare list and there is no way to tell a
    # headline reading from one that exists only inside a compound. 湯 tāng
    # answers a search for yáng because kHanyuPinyin records 湯谷 yánggǔ. It is
    # correct, and it looks wrong until you can see the reading.
    #
    # With a second system constrained, its reading is shown too: a Mandarin +
    # Middle Chinese search reports both, which is the comparison the reader
    # asked for rather than a Mandarin answer with an invisible MC filter
    # behind it.
    #
    # Costs no extra query: every field involved is already hydrated for the
    # row by #system_fields.
    def matched_readings(properties, rime_hits = {}, codepoint_id = nil)
      @constraint_slots.map do |entry|
        system = entry[:system]
        readings =
          if rime_hits.key?(system)
            Array(rime_hits[system][codepoint_id]).map do |label|
              { reading: label, field: nil, source: ReadingSystem.definition(system)[:source],
                system: system }
            end
          else
            readings_matching(properties, system, entry[:slots])
          end

        { system: system, readings: readings }
      end
    end

    def readings_matching(properties, system, wanted)
      show_all = wanted.nil?
      return [] if !show_all && wanted.empty?

      reading_systems_for(system).flat_map do |id|
        field = ReadingSystem.definition(id)&.fetch(:field, nil)
        next [] if field.blank?

        Array(properties[field]).flat_map do |entry|
          ReadingSystem.readings_in(entry[:value], id).filter_map do |reading|
            slot, tone = ReadingSystem.split(reading, id)
            next if slot.blank?
            unless show_all
              next unless wanted.any? { |want_slot, want_tone| slot == want_slot && (want_tone.nil? || want_tone.to_i == tone.to_i) }
            end

            { reading: reading, field: field, source: entry[:source], system: id }
          end
        end
      end.uniq { |hit| [hit[:reading], hit[:field]] }
    end

    # slots nil means "show this system's readings, constrain nothing".
    # slots [] means the constraint found nothing and contributes no column.
    def record_constraint(system, slots)
      return if slots && slots.empty?

      @constraint_slots << { system: system.to_s, slots: slots }
    end

    # Constrained by codepoint id, so the (character_codepoint_id, field) index
    # applies and the missing source is not a problem here.
    def property_rows(ids, fields)
      return {} if fields.empty?

      CharacterProperty
        .where(character_codepoint_id: ids, field: fields)
        .order(:field, :source, :value)
        .pluck(:character_codepoint_id, :field, :source, :value)
        .each_with_object({}) do |(ccid, field, source, value), acc|
          ((acc[ccid] ||= {})[field] ||= []) << { value: value.to_s, source: source.to_s }
        end
    end

    # Verbatim entry text, kept per work so the renderer can attribute each
    # quotation to the work it came from.
    def dictionary_entry_rows(ids)
      dictionary_scope(ids)
        .where("dw_work.id IN (?)", @dictionary_columns)
        .pluck(Arel.sql(<<~SQL.squish))
          dictionary_entry_characters.character_codepoint_id,
          dw_work.id, dw_work.title, dw_work.edition_label,
          de.headword, de.definition, de.small_rime_number,
          ds.tone, ds.rhyme_label
        SQL
        .each_with_object({}) do |row, acc|
          ccid, work_id, title, edition, headword, definition, small_rime, tone, rhyme = row
          (acc[ccid] ||= []) << {
            work_id: work_id, work_title: title, edition_label: edition,
            headword: headword, definition: definition,
            small_rime_number: small_rime, tone: tone, rhyme_label: rhyme
          }
        end
    end

    # Every field every constrained system read from — including each system's
    # rare companion — so a matched reading can be shown as the reason for the
    # row without a second round of queries.
    def system_fields
      @constraint_slots
        .flat_map { |entry| reading_systems_for(entry[:system]) }
        .filter_map { |system| ReadingSystem.definition(system)&.fetch(:field, nil) }
        .uniq
    end

    def coverage_report
      systems = ([@system] + @constraints.map { |c| c[:system].to_s }).uniq.reject(&:blank?)
      systems.index_with do |system|
        SlotIndex.coverage(system)
      rescue SlotIndex::Unsupported
        nil
      end.compact
    end

    # Steps carry structured detail, never a pre-formatted string. The view
    # phrases the common cases in plain language and keeps field names and
    # sources for the technical panel.
    def record_step(kind, remaining, **detail)
      @steps << { kind: kind, remaining: remaining, detail: detail }
    end
  end
end
