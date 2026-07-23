# frozen_string_literal: true

module DictionaryCatalogue
  # Read-only Kangxi radical/stroke structure derived from canonical sources:
  #
  # - radical catalogue and radical metadata: normalized Kangxi dictionary sections
  # - per-character radical membership: Unihan kRSUnicode CharacterProperty rows
  #
  # This replaces the old kangxi_radicals and character_radical_memberships tables.
  # Nothing is cached in a second database table, so the character-property source
  # and the normalized dictionary cannot silently drift apart.
  class KangxiStructure
    WORK_ID = 127_355
    FIELD = "kRSUnicode"

    Membership = Struct.new(
      :radical_number,
      :additional_strokes,
      :raw_token,
      keyword_init: true
    )

    Radical = Struct.new(
      :number,
      :radical,
      :variants,
      :stroke_count,
      :meaning,
      :colloquial_names,
      :pinyin,
      :sino_vietnamese,
      :japanese,
      :korean,
      :frequency,
      :simplified,
      :examples,
      keyword_init: true
    )

    Record = Struct.new(
      :character_codepoint_id,
      :membership,
      :radical,
      :total_strokes,
      keyword_init: true
    )

    class << self
      def for_character_ids(character_codepoint_ids)
        ids = Array(character_codepoint_ids).compact.map(&:to_i).select(&:positive?).uniq
        return {} if ids.empty?

        radicals = radical_catalogue
        properties = CharacterProperty
          .where(character_codepoint_id: ids, field: FIELD)
          .order(:character_codepoint_id, :id)
          .pluck(:character_codepoint_id, :value)

        memberships = {}
        properties.each do |character_codepoint_id, raw_value|
          parsed = tokenize(raw_value).filter_map { |token| parse_token(token) }
          next if parsed.empty?

          selected = parsed.min_by do |membership|
            [membership.additional_strokes, membership.radical_number, membership.raw_token]
          end
          memberships[character_codepoint_id] ||= selected
        end

        ids.each_with_object({}) do |character_codepoint_id, result|
          membership = memberships[character_codepoint_id]
          next unless membership

          radical = radicals[membership.radical_number]
          total_strokes = if radical&.stroke_count
            radical.stroke_count.to_i + membership.additional_strokes.to_i
          end

          result[character_codepoint_id] = Record.new(
            character_codepoint_id: character_codepoint_id,
            membership: membership,
            radical: radical,
            total_strokes: total_strokes
          )
        end
      end

      def radical_catalogue
        @radical_catalogue ||= begin
          work = DictionaryWork.find_by(corpus_work_id: WORK_ID)
          if work.nil?
            {}
          else
            work.dictionary_sections.order(:sequence_number).each_with_object({}) do |section, result|
            metadata = section.metadata.is_a?(Hash) ? section.metadata : {}
            number = section.sequence_number.to_i
            result[number] = Radical.new(
              number: number,
              radical: metadata["radical"].presence || section.label.to_s.sub(/部\z/, ""),
              variants: metadata["variants"],
              stroke_count: integer_or_nil(metadata["stroke_count"]),
              meaning: metadata["meaning"],
              colloquial_names: metadata["colloquial_names"],
              pinyin: metadata["pinyin"],
              sino_vietnamese: metadata["sino_vietnamese"],
              japanese: metadata["japanese"],
              korean: metadata["korean"],
              frequency: integer_or_nil(metadata["frequency"]),
              simplified: metadata["simplified"],
              examples: metadata["examples"]
            )
            end
          end
        end
      end

      def reset_cache!
        @radical_catalogue = nil
      end

      def tokenize(value)
        value.to_s.strip.split(/\s+/).reject(&:empty?)
      end

      def parse_token(token)
        match = token.to_s.match(/\A(?<radical>\d+)(?:')?\.(?<additional>\d+)\z/)
        return nil unless match

        Membership.new(
          radical_number: match[:radical].to_i,
          additional_strokes: match[:additional].to_i,
          raw_token: token.to_s
        )
      end

      private

      def integer_or_nil(value)
        Integer(value, exception: false)
      end
    end
  end
end
