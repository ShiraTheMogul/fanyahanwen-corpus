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

    SORTS = %w[radical stroke pronunciation frequency importance kind].freeze

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
      elsif !truthy?(needed) && importance.blank? && category.blank?
        # Individual uses live inside their function-word tile by default. They
        # remain directly browsable through the Entry type and taxonomy filters,
        # as well as the Articles needed view.
        rows = rows.reject { |row| row.entry.parent_id.present? }
      end
      rows = rows.select { |row| row.entry.importance == importance.to_s } if importance.present?
      rows = rows.select { |row| row.entry.categories.include?(category.to_s) } if category.present?
      rows = rows.reject(&:published) if truthy?(needed)

      rows.sort_by { |row| sort_key(row, sort) }
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
      memberships = CharacterRadicalMembership
        .where(character_codepoint_id: character_ids.values)
        .order(:additional_strokes, :radical_number)
        .to_a
        .group_by(&:character_codepoint_id)
        .transform_values(&:first)
      radical_numbers = memberships.values.map(&:radical_number).compact.uniq
      radicals = KangxiRadical.where(number: radical_numbers).index_by(&:number)
      readings = include_pronunciation ? pronunciation_map(character_ids) : {}
      frequencies = include_frequency ? frequency_map(character_entries) : {}

      entries.map do |entry|
        character_id = character_ids[entry.headword.ord] if entry.single_character?
        membership = memberships[character_id] if character_id
        radical = radicals[membership.radical_number] if membership
        total_strokes =
          if radical&.stroke_count && membership&.additional_strokes
            radical.stroke_count.to_i + membership.additional_strokes.to_i
          end

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

    def importance_rank(value)
      Entry::IMPORTANCE.index(value.to_s) || 999
    end

    def truthy?(value)
      value == true || %w[1 true yes on].include?(value.to_s.downcase)
    end
  end
end
