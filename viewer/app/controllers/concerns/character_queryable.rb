# frozen_string_literal: true

# The constraint engine's controller surface. Lives in a concern so
# ToolsController picks it up with a single `include` line and no existing
# method is touched.
#
# Both actions are POST. Every other tool on the page is POST for a reason:
# tools_picker_controller stores the open panel in the URL hash
# (`#tool-character-query`) and re-reads it on popstate, so an action that
# changes the path or query string leaves the picker with no panel to reopen
# and the back button lands on the chooser. A GET form here broke exactly that.
#
# Neither action is allowed to raise. An unhandled exception renders Rails's
# error page inside the Turbo frame, which wrecks the panel and the history
# entry with it.
module CharacterQueryable
  extend ActiveSupport::Concern

  CHARACTER_QUERY_FRAME = "character_query_out"
  CHARACTER_QUERY_SLOTS_FRAME = "character_query_slots_out"
  MAX_SECONDARY_CONSTRAINTS = 3
  CHARACTER_QUERY_SLOT_EXAMPLES = 6

  # POST /tools/character_query
  def character_query
    system = params[:system].to_s
    spec = params[:slot].to_s.strip

    return character_query_error(I18n.t("character_query.errors.unknown_system")) unless CharacterQuery::ReadingSystem.known?(system)

    # A syllable, a character, a component or an IDS sequence — any one is
    # enough to start from, and at least one is required.
    if spec.blank? && params[:homophone_of].blank? && params[:component].blank? && params[:ids_expression].blank?
      return character_query_error(I18n.t("character_query.errors.missing_criteria"))
    end

    if spec.present? && CharacterQuery::ReadingSystem.parse_spec(spec, system, scheme: params[:scheme]).first.blank?
      return character_query_error(I18n.t("character_query.errors.unparsable_slot", spec: spec))
    end

    slot, tone = CharacterQuery::ReadingSystem.parse_spec(spec, system, scheme: params[:scheme])
    csv = params[:download].to_s == "csv"

    result = CharacterQuery::Query.new(
      system: system,
      slot: slot,
      tone: tone,
      homophone_of: params[:homophone_of],
      match_tone: params[:match_tone],
      component: params[:component],
      ids_expression: params[:ids_expression],
      constraints: character_query_secondary_constraints,
      dictionary_filters: character_query_dictionary_filters,
      columns: character_query_columns,
      dictionary_columns: Array(params[:dictionary_columns]),
      radical: params[:radical].to_s.strip,
      total_strokes: params[:total_strokes],
      common_only: params[:common_only],
      combine: params[:combine],
      group_variants: params[:group_variants],
      # A download is never a page. Whatever is on screen, the file holds
      # every character the constraints matched.
      page: csv ? 1 : params[:page],
      per_page: csv ? CharacterQuery::Query::ALL : character_query_per_page
    ).call

    if csv
      return send_data character_query_csv(result),
                       filename: "character-query-#{system.tr(':', '-')}-#{slot}#{tone}.csv",
                       type: "text/csv; charset=utf-8"
    end

    annotation = CharacterQuery::AnnotationRenderer.new(
      result.rows,
      gloss_field: params[:gloss_field],
      reading_field: CharacterQuery::ReadingSystem.definition(system)&.fetch(:field, nil)
    )

    render partial: "tools/character_query_output",
           locals: character_query_defaults.merge(
             result: result,
             system: system,
             slot: slot,
             tone: tone,
             annotation_entries: annotation.to_entries,
             annotation_text: annotation.to_text,
             output_mode: params[:output_mode].to_s == "annotation" ? "annotation" : "table"
           )
  rescue StandardError => error
    character_query_report(error)
    character_query_error(I18n.t("character_query.errors.unexpected"))
  end

  # POST /tools/character_query/slots
  def character_query_slots
    system = params[:system].presence || "mandarin"

    unless CharacterQuery::ReadingSystem.known?(system)
      return render partial: "tools/character_query_slots_output",
                    locals: { system: system, slots: [], message: I18n.t("character_query.errors.unknown_system") }
    end

    # A rime book has no syllable inventory to list. It spells with 反切, and
    # the romanisations that exist — Baxter, Pulleyblank, Karlgren — are each
    # someone's reading of that spelling, so there is no list of syllables
    # that belongs to the book itself. Said plainly, rather than raised and
    # reported as an unexpected error.
    if CharacterQuery::ReadingSystem.rime_book?(system)
      return render partial: "tools/character_query_slots_output",
                    locals: { system: system, slots: [],
                              message: I18n.t("character_query.errors.no_inventory_for_rime_book") }
    end

    index = CharacterQuery::SlotIndex.for(system)
    slots = index.map do |slot, bucket|
      ids = Array(bucket["all"] || bucket[:all])
      {
        slot: slot,
        count: ids.size,
        sample_ids: ids.first(CHARACTER_QUERY_SLOT_EXAMPLES),
        tones: (bucket["tones"] || bucket[:tones] || {}).transform_values { |list| Array(list).size }
      }
    end.sort_by { |row| [-row[:count], row[:slot]] }

    # A syllable on its own tells you nothing about what it sounds like or what
    # sits in it. A handful of characters makes the inventory readable to
    # someone hunting for a slot they cannot yet spell — which is most people
    # arriving at a topolect's IPA for the first time.
    glyphs = character_query_glyphs(slots.flat_map { |row| row[:sample_ids] })
    slots.each { |row| row[:examples] = row.delete(:sample_ids).filter_map { |id| glyphs[id] } }

    render partial: "tools/character_query_slots_output",
           locals: { system: system, slots: slots, message: nil }
  rescue StandardError => error
    character_query_report(error)
    render partial: "tools/character_query_slots_output",
           locals: { system: system, slots: [], message: I18n.t("character_query.errors.unexpected") }
  end

  private

  # Logged for you, not shown to the visitor. Deliberately not re-raised in
  # development either: a raised error here takes the Turbo frame and the
  # picker's history entry down with it, which is harder to diagnose than a
  # log line.
  def character_query_report(error)
    Rails.logger.error("[character_query] #{error.class}: #{error.message}")
    Rails.logger.error(Array(error.backtrace).first(8).join("\n"))
  end

  # One query for every example across the whole inventory, rather than one
  # per slot. Roughly 500 slots × 6 examples is 3,000 primary-key lookups in a
  # single statement.
  def character_query_glyphs(ids)
    return {} if ids.empty?

    CharacterCodepoint.where(id: ids.uniq).pluck(:id, :chr).to_h
  end

  def character_query_error(message)
    render partial: "tools/character_query_output",
           locals: character_query_defaults.merge(message: message)
  end

  def character_query_defaults
    {
      message: nil,
      result: nil,
      system: params[:system].to_s,
      slot: nil,
      tone: nil,
      annotation_entries: [],
      annotation_text: "",
      output_mode: "table"
    }
  end

  # "all" survives as itself; anything else becomes a positive integer. The
  # offered sizes are a convenience, not a gate — a hand-typed per_page is
  # honoured, because the point of dropping the row cap was to stop the tool
  # deciding how much of the answer the reader is allowed to see.
  def character_query_per_page
    raw = params[:per_page].to_s.strip
    return CharacterQuery::Query::DEFAULT_PER_PAGE if raw.empty?
    return CharacterQuery::Query::ALL if raw.casecmp?("all")

    raw
  end

  def character_query_secondary_constraints
    systems = Array(params[:secondary_system])
    slots = Array(params[:secondary_slot])
    schemes = Array(params[:secondary_scheme])

    # A blank syllable is never "an empty row to ignore". With a character
    # given above it means "whatever that character reads as in this system";
    # without one it means "show this system's reading for every result".
    # Query decides which, so the row is always passed through.
    systems.first(MAX_SECONDARY_CONSTRAINTS).each_with_index.filter_map do |system, index|
      system = system.to_s
      spec = slots[index].to_s.strip
      next if system.blank?
      next unless CharacterQuery::ReadingSystem.known?(system)

      next { system: system, slot: nil, tone: nil } if spec.blank?

      slot, tone = CharacterQuery::ReadingSystem.parse_spec(spec, system, scheme: schemes[index])
      next if slot.blank?

      { system: system, slot: slot, tone: tone }
    end
  end

  # Every facet here belongs to ONE book, so the book travels with them and
  # Query refuses the set without it.
  #
  # dictionary_work_id arrives from the picker as "rimebook:4", which is the
  # same id the reading-system dropdowns use, so the book can be named in one
  # vocabulary throughout. A bare integer is still accepted, for a console
  # call or an old bookmark.
  #
  # The tone parameter was called mc_tone. It is not renamed for tidiness:
  # 洪武正韻 is Ming, 1375, and its 平聲 is not a Middle Chinese category, so a
  # parameter called mc_tone carrying it was itself a small false claim.
  def character_query_dictionary_filters
    {
      work_id: character_query_work_id,
      tone: params[:rime_tone],
      rhyme_label: params[:rhyme_label],
      small_rime: params[:small_rime],
      fanqie: params[:fanqie]
    }.compact_blank
  end

  def character_query_work_id
    raw = params[:dictionary_work_id].to_s.strip
    return nil if raw.empty?

    CharacterQuery::RimeBooks.work_id_from(raw) || raw
  end

  # Reuses the enricher's field vocabulary in place. ENRICHABLE_FIELD_OPTIONS
  # is not moved, re-homed or refactored — it is read where it lives.
  def character_query_columns
    allowed = ToolsController::ENRICHABLE_FIELD_OPTIONS.keys
    Array(params[:columns]).map(&:to_s).select { |field| allowed.include?(field) }
  end

  def character_query_csv(result)
    fields = character_query_columns

    CSV.generate(encoding: Encoding::UTF_8) do |csv|
      csv << [
        I18n.t("tools.common.character"),
        I18n.t("tools.common.codepoint")
      ] + fields.map { |field| I18n.t(ToolsController::ENRICHABLE_FIELD_OPTIONS.fetch(field, field)) }

      result.rows.each do |row|
        csv << [row[:char], "U+#{row[:codepoint].to_i.to_s(16).upcase}"] +
               fields.map do |field|
                 Array(row.dig(:properties, field)).map { |entry| entry[:value] }.uniq.join(" / ")
               end
      end
    end
  end

  # === form data =========================================================
  #
  # Three dependent dropdowns: language family, then language or branch, then
  # the specific system or locality. Genetic family at the top because "Wu"
  # was never a unit a visitor could pick and be done with — Wu speakers do
  # not all follow Shanghainese, so the locality is the real unit and the
  # branch is only how you reach it.
  #
  # The third dropdown is hidden when a branch offers exactly one system, so
  # Japanese or Vietnamese take two choices rather than three.

  included do
    helper_method :character_query_picker
  end

  def character_query_picker
    @character_query_picker ||= begin
      families = []
      branches = {}
      systems = {}
      singles = {}

      CharacterQuery::FamilyRegistry.family_keys.each do |family|
        family_branches = CharacterQuery::FamilyRegistry.branches_for(family)
        next if family_branches.empty?

        families << [I18n.t("character_query.families.#{family}", default: family.humanize), family]

        branches[family] = family_branches.map do |branch|
          [I18n.t("character_query.branches.#{branch[:key]}", default: branch[:key].humanize),
           branch[:key],
           I18n.t("character_query.branch_hints.#{branch[:key]}", default: "")]
        end

        family_branches.each do |branch|
          key = "#{family}/#{branch[:key]}"
          singles[key] = branch[:single_system]
          next if branch[:single_system]

          systems[key] = CharacterQuery::FamilyRegistry.options_for_branch(family, branch[:key])
        end
      end

      {
        "families" => families,
        "branches" => branches,
        "systems" => systems,
        "singles" => singles,
        # Systems where ü is a letter distinction rather than a tone mark, so
        # the view knows when the v-for-ü affordance is relevant.
        "pinyin_systems" => CharacterQuery::ReadingSystem::DEFINITIONS
                            .select { |_, d| d[:tone] == :pinyin && !d[:hidden] }.keys,
        "labels" => {
          "named" => I18n.t("character_query.groups.named_systems"),
          "rime_books" => I18n.t("character_query.groups.rime_books"),
          "common" => I18n.t("character_query.groups.common_choices"),
          "all" => I18n.t("character_query.groups.all_localities")
        }
      }
    end
  end
end
