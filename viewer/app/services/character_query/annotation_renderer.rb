# frozen_string_literal: true

module CharacterQuery
  # Renders a shortlist into an annotation block in the house format:
  #
  #   鷖 yī - Seagull, syn. 鷗 (source)
  #   《集韻》煙奚切，𠀤音翳。水鳥。鷗也。一名水鴞。
  #
  # The English gloss is the one field that cannot be supplied at publication
  # quality. Kroll and Pleco content are under copyright and are not in the
  # database; what is available is Unihan's kDefinition, CC-CEDICT, and the
  # Chinese-medium classical entries. So where the only candidate gloss comes
  # from a source that is not citable for this purpose, the slot is emitted as
  # a marker for the author to fill, and never as an invented gloss with a
  # borrowed attribution.
  class AnnotationRenderer
    GLOSS_MARKER = "[gloss]"

    # Fields treated as an English gloss, in order of preference.
    GLOSS_FIELDS = %w[kDefinition cedict_def].freeze

    # Fields treated as a reading for the headword line.
    READING_FIELDS = %w[kMandarin kHanyuPinyin].freeze

    def initialize(rows, gloss_field: nil, reading_field: "kMandarin", include_sources: true)
      @rows = Array(rows)
      @gloss_field = gloss_field.presence
      @reading_field = reading_field.presence || "kMandarin"
      @include_sources = include_sources
    end

    def to_text
      @rows.map { |row| block_for(row).join("\n") }.join("\n\n")
    end

    # One entry per character, so a view can render each block and mark the
    # ones still needing an authored gloss.
    def to_entries
      @rows.map do |row|
        gloss = gloss_for(row)
        {
          char: row[:char],
          codepoint: row[:codepoint],
          reading: reading_for(row),
          gloss: gloss[:text],
          gloss_source: gloss[:source],
          gloss_needs_author: gloss[:needs_author],
          quotations: quotations_for(row)
        }
      end
    end

    private

    def block_for(row)
      entry = {
        char: row[:char],
        reading: reading_for(row),
        gloss: gloss_for(row),
        quotations: quotations_for(row)
      }

      head = +"#{entry[:char]}"
      head << " #{entry[:reading]}" if entry[:reading].present?
      head << " - #{entry[:gloss][:text]}"
      if @include_sources && entry[:gloss][:source].present?
        head << " (#{entry[:gloss][:source]})"
      end

      [head] + entry[:quotations].map { |q| quotation_line(q) }
    end

    def quotation_line(quotation)
      title = quotation[:work_title].to_s
      body = quotation[:text].to_s
      title.present? ? "《#{title}》#{body}" : body
    end

    def reading_for(row)
      fields = @reading_field == "kMandarin" ? READING_FIELDS : [@reading_field]
      fields.each do |field|
        values = values_of(row, field)
        return values.first if values.any?
      end
      nil
    end

    def gloss_for(row)
      candidates = @gloss_field ? [@gloss_field] : GLOSS_FIELDS
      candidates.each do |field|
        values = values_of(row, field)
        next if values.empty?

        return { text: values.first, source: source_of(row, field), needs_author: false }
      end

      { text: GLOSS_MARKER, source: nil, needs_author: true }
    end

    # Verbatim classical entries, attributed to the work they came from.
    def quotations_for(row)
      Array(row[:dictionary_entries]).filter_map do |entry|
        text = entry[:definition].presence
        next if text.blank?

        {
          work_title: entry[:work_title],
          edition_label: entry[:edition_label],
          text: collapse(text)
        }
      end
    end

    def values_of(row, field)
      Array(row.dig(:properties, field)).map { |entry| collapse(entry[:value]) }.reject(&:blank?).uniq
    end

    def source_of(row, field)
      Array(row.dig(:properties, field)).map { |entry| entry[:source] }.compact_blank.first
    end

    def collapse(text)
      text.to_s.gsub(/[\n\r\t]+/, " ").gsub(/\s{2,}/, " ").strip
    end
  end
end
