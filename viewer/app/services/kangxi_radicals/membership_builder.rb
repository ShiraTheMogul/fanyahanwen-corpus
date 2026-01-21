# frozen_string_literal: true

module KangxiRadicals
  class MembershipBuilder
    FIELD = "kRSUnicode"
    BATCH = 5_000

    def self.rebuild!
      CharacterRadicalMembership.delete_all

      rows = []
      now = Time.current

      # Rails batching uses the primary key cursor by default (usually :id).
      # If you add a custom select, you MUST include the cursor column(s), or Rails will raise.
      #
      # Pattern:
      # - Either don't use a custom select with find_in_batches
      # - Or include :id (and any other cursor columns) in the select
      CharacterProperty
        .where(field: FIELD)
        .select(:id, :character_codepoint_id, :value)
        .find_in_batches(batch_size: BATCH) do |batch|

        batch.each do |prop|
          ccid = prop.character_codepoint_id
          next if ccid.nil? # defensive: skip broken rows

          tokenize(prop.value).each do |token|
            parsed = parse_token(token)
            next unless parsed

            rows << {
              character_codepoint_id: ccid,
              radical_number: parsed[:radical_number],
              additional_strokes: parsed[:additional_strokes],
              raw_token: token,
              created_at: now,
              updated_at: now
            }
          end
        end

        if rows.length >= BATCH
          CharacterRadicalMembership.insert_all(rows)
          rows.clear
        end
      end

      CharacterRadicalMembership.insert_all(rows) if rows.any?
    end

    def self.tokenize(value)
      value.to_s.strip.split(/\s+/).reject(&:empty?)
    end

    def self.parse_token(token)
      m = token.match(/\A(?<rad>\d+)(?:')?\.(?<add>\d+)\z/)
      return nil unless m

      {
        radical_number: m[:rad].to_i,
        additional_strokes: m[:add].to_i
      }
    end
  end
end
