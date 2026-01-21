module KangxiRadicals
  class CharacterFinder
    # Find characters for a given Kangxi radical number using Unihan kRSUnicode.
    #
    # kRSUnicode is stored in character_properties.value as strings like:
    #   32.9
    #   32.9 75.4 (multiple tokens)
    #
    # This service returns CharacterCodepoint rows in Unicode codepoint order.

    def initialize(radical_number)
      @radical_number = Integer(radical_number)
    end

    def characters
      cc_ids = matching_character_codepoint_ids
      return CharacterCodepoint.none if cc_ids.empty?

      # Unicode order = numeric codepoint order.
      CharacterCodepoint.where(id: cc_ids).order(:codepoint)
    end

    private

    attr_reader :radical_number

    def matching_character_codepoint_ids
      # We need to match tokens like:
      #   "32." at the start of the string
      #   " 32." after a space (later token)
      # Also allow the Unihan apostrophe form: 32'.9

      n = radical_number.to_s
      patterns = [
        "#{n}.",
        " #{n}.",
        "#{n}'.",
        " #{n}'.",
      ]

      scope = CharacterProperty.where(field: "kRSUnicode")

      # Build OR LIKE conditions in a loop so adding more patterns later is easy.
      conditions = patterns.map { "value LIKE ?" }.join(" OR ")
      binds = patterns.map { |p| "#{p}%" }

      scope
        .where(conditions, *binds)
        .distinct
        .pluck(:character_codepoint_id)
    end
  end
end
