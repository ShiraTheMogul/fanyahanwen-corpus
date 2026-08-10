# frozen_string_literal: true

module CharacterData
  class CodepointResolver
    class << self
      def resolve_glyph(glyph)
        text = glyph.to_s
        raise ArgumentError, "glyph is not one indexable Unicode character" unless IndexableCharacter.single?(text)

        resolve(codepoint: text.ord, glyph: text)
      end

      def resolve(codepoint:, glyph: nil)
        codepoint = Integer(codepoint)
        glyph ||= [codepoint].pack("U")

        unless IndexableCharacter.single?(glyph) && glyph.ord == codepoint
          raise ArgumentError, "codepoint and glyph do not identify the same indexable Unicode character"
        end

        CharacterCodepoint.find_or_create_by!(codepoint: codepoint) do |row|
          row.chr = glyph
        end
      end
    end
  end
end
