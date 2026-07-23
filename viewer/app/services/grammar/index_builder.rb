# frozen_string_literal: true

module Grammar
  class IndexBuilder
    Row = Struct.new(
      :entry,
      :published,
      :status,
      :radical_number,
      :radical_glyph,
      :additional_strokes,
      :total_strokes,
      :pronunciation,
      :corpus_frequency,
      :children,
      keyword_init: true
    )

    Group = Struct.new(
      :type,
      :value,
      :rows,
      :radical_number,
      :radical_glyph,
      keyword_init: true
    )

    SORTS = %w[radical stroke importance kind category pronunciation frequency].freeze

    def initialize(store: EntryStore.default, locale: I18n.locale, pronunciation_source: :mandarin)
      @store = store
      @locale = locale.to_s
      @pronunciation_source = pronunciation_source.to_s.strip.downcase.tr(" ", "_").to_sym
    end

    def rows(sort: "radical", kind: nil, importance: nil, category: nil, needed: false)
      sort = SORTS.include?(sort.to_s) ? sort.to_s : "radical"
      rows = build_rows(
        include_pronunciation: sort == "pronunciation",
        include_frequency: sort == "frequency"
      )
      children_by_parent = rows.select { |row| row.entry.parent_id }.group_by { |row| row.entry.parent_id }
      rows.each { |row| row.children = children_by_parent.fetch(row.entry.id, []) }

      if kind.present?
        rows = rows.select { |row| row.entry.kind == kind.to_s }
      elsif nest_individual_uses?(sort, importance: importance, category: category, needed: needed)
        # Character-led arrangements keep individual uses inside their parent
        # tile. Taxonomy-led arrangements show those uses as entries in their
        # own right, because their type, importance, and categories may differ
        # from the parent function word.
        rows = rows.reject { |row| row.entry.parent_id.present? }
      end
      rows = rows.select { |row| row.entry.importance == importance.to_s } if importance.present?
      rows = rows.select { |row| row.entry.categories.include?(category.to_s) } if category.present?
      rows = rows.reject(&:published) if truthy?(needed)

      rows.sort_by { |row| sort_key(row, sort) }
    end

    # Arrangement is expressed as visible sections rather than repeated labels
    # inside every tile. Category entries may legitimately appear in more than
    # one section because an entry can belong to several grammatical categories.
    def groups(rows, sort: "radical")
      sort = SORTS.include?(sort.to_s) ? sort.to_s : "radical"

      case sort
      when "radical"
        radical_groups(rows).map do |(number, glyph), grouped_rows|
          Group.new(
            type: "radical",
            value: number,
            rows: grouped_rows,
            radical_number: number,
            radical_glyph: glyph
          )
        end
      when "stroke"
        grouped_values(rows, :total_strokes, type: "stroke")
      when "importance"
        ordered_groups(rows, Entry::IMPORTANCE, type: "importance") { |row| row.entry.importance.presence }
      when "kind"
        ordered_groups(rows, Entry::KINDS, type: "kind") { |row| row.entry.kind.presence }
      when "category"
        category_groups(rows)
      when "pronunciation"
        pronunciation_groups(rows)
      else
        [Group.new(type: sort, value: nil, rows: rows)]
      end
    end

    def radical_groups(rows)
      rows.group_by do |row|
        if row.radical_number
          [row.radical_number, row.radical_glyph]
        else
          [nil, nil]
        end
      end
    end

    private

    def build_rows(include_pronunciation:, include_frequency:)
      entries = @store.all
      character_entries = entries.select(&:single_character?)
      codepoints = character_entries.map { |entry| entry.headword.ord }

      character_ids = CharacterCodepoint.where(codepoint: codepoints).pluck(:codepoint, :id).to_h
      kangxi_structure = DictionaryCatalogue::KangxiStructure.for_character_ids(character_ids.values)
      readings = include_pronunciation ? pronunciation_map(character_ids) : {}
      frequencies = include_frequency ? frequency_map(character_entries) : {}

      entries.map do |entry|
        character_id = character_ids[entry.headword.ord] if entry.single_character?
        structure = kangxi_structure[character_id] if character_id
        membership = structure&.membership
        radical = structure&.radical
        total_strokes = structure&.total_strokes

        published = @store.article_exists?(entry, locale: @locale) ||
          (@locale != EntryStore::SOURCE_LOCALE && @store.article_exists?(entry, locale: EntryStore::SOURCE_LOCALE))

        Row.new(
          entry: entry,
          published: published,
          status: status_for(entry, published),
          radical_number: membership&.radical_number,
          radical_glyph: radical&.radical,
          additional_strokes: membership&.additional_strokes,
          total_strokes: total_strokes,
          pronunciation: readings[character_id],
          corpus_frequency: frequencies[entry.headword],
          children: []
        )
      end
    end

    def pronunciation_map(character_ids)
      source = PronunciationRegistry.ruby_source(@pronunciation_source)
      return {} unless source
      return {} if source[:special].present?

      allowed_sources = Array(source[:sources]).map(&:to_s)
      source_rank = allowed_sources.each_with_index.to_h
      properties = CharacterProperty
        .where(character_codepoint_id: character_ids.values, field: source[:field])
        .to_a
        .select { |property| allowed_sources.empty? || allowed_sources.include?(property.source.to_s) }

      properties.group_by(&:character_codepoint_id).transform_values do |rows|
        raw = rows.min_by { |property| [source_rank.fetch(property.source.to_s, 999), property.value.to_s] }&.value.to_s
        raw.strip.split(/\s+/).first
      end
    end

    def frequency_map(_entries)
      CorpusSearch::FrequencySnapshot.counts
    end

    def status_for(entry, published)
      return "article_needed" unless published
      return "needs_expansion" if entry.needs_expansion?

      "published"
    end

    def sort_key(row, sort)
      entry = row.entry

      case sort
      when "stroke"
        [row.total_strokes || 999, row.radical_number || 999, row.additional_strokes || 999, entry.headword, entry.id]
      when "pronunciation"
        [row.pronunciation.to_s.empty? ? 1 : 0, row.pronunciation.to_s.downcase, entry.headword, entry.id]
      when "frequency"
        [row.corpus_frequency.nil? ? 1 : 0, -(row.corpus_frequency || 0), entry.headword, entry.id]
      when "importance"
        [importance_rank(entry.importance), entry.headword, entry.id]
      when "kind"
        [Entry::KINDS.index(entry.kind) || 999, entry.headword, entry.id]
      when "category"
        [entry.categories.first.to_s, entry.headword, entry.id]
      else
        [
          entry.kind == "function_word" ? 0 : 1,
          row.radical_number || 999,
          row.additional_strokes || 999,
          entry.headword,
          entry.id
        ]
      end
    end

    def grouped_values(rows, method_name, type:)
      rows.group_by { |row| row.public_send(method_name) }
        .sort_by { |value, _| value.nil? ? [1, 0] : [0, value] }
        .map { |value, grouped_rows| Group.new(type: type, value: value, rows: grouped_rows) }
    end

    def ordered_groups(rows, order, type:)
      grouped = rows.group_by { |row| yield(row) }
      values = order.select { |value| grouped.key?(value) }
      values << nil if grouped.key?(nil)

      values.map do |value|
        Group.new(type: type, value: value, rows: grouped.fetch(value))
      end
    end

    def category_groups(rows)
      grouped = Hash.new { |hash, key| hash[key] = [] }
      rows.each do |row|
        categories = row.entry.categories.presence || [nil]
        categories.each { |category| grouped[category] << row }
      end

      catalogue_order = @store.all.flat_map(&:categories).uniq
      values = catalogue_order.select { |value| grouped.key?(value) }
      values.concat((grouped.keys.compact - values).sort)
      values << nil if grouped.key?(nil)

      values.map do |value|
        Group.new(type: "category", value: value, rows: grouped.fetch(value))
      end
    end

    def pronunciation_groups(rows)
      grouped = rows.group_by { |row| pronunciation_initial(row.pronunciation) }
      values = grouped.keys.compact.sort
      values << nil if grouped.key?(nil)

      values.map do |value|
        Group.new(type: "pronunciation", value: value, rows: grouped.fetch(value))
      end
    end

    def pronunciation_initial(value)
      text = value.to_s.strip
      return nil if text.empty?

      normalized = text.unicode_normalize(:nfd).gsub(/\p{Mn}/, "")
      initial = normalized[/\A./m]
      initial&.upcase
    end

    def nest_individual_uses?(sort, importance:, category:, needed:)
      return false if truthy?(needed) || importance.present? || category.present?

      !%w[importance kind category].include?(sort)
    end

    def importance_rank(value)
      Entry::IMPORTANCE.index(value.to_s) || 999
    end

    def truthy?(value)
      value == true || %w[1 true yes on].include?(value.to_s.downcase)
    end
  end
end
