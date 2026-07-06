# frozen_string_literal: true

module CorpusSearch
  # Compact, query-independent record of which characters may occur in a body.
  #
  # This is used only to put promising cached documents near the front of a
  # bounded interactive scan. Bloom filters can return false positives, so they
  # must never be used to claim that a document definitely matches. They do not
  # return false negatives for a current body, which makes them safe as a
  # prioritisation hint.
  module CharacterBloom
    BIT_COUNT = 4_096
    BYTE_COUNT = BIT_COUNT / 8
    HASH_SEEDS = [
      0x9e3779b97f4a7c15,
      0xbf58476d1ce4e5b9,
      0x94d049bb133111eb,
      0x2545f4914f6cdd1d
    ].freeze
    MASK_64 = (1 << 64) - 1

    module_function

    def build(text)
      bytes = "\0".b * BYTE_COUNT
      text.to_s.each_codepoint.uniq.each do |codepoint|
        positions_for(codepoint).each do |position|
          byte_index = position >> 3
          bytes.setbyte(byte_index, bytes.getbyte(byte_index) | (1 << (position & 7)))
        end
      end
      bytes.freeze
    end

    def maybe_matches?(blob, term_patterns:, alternatives: false)
      data = blob.to_s.b
      return false unless data.bytesize == BYTE_COUNT

      term_results = Array(term_patterns).map do |pattern|
        Array(pattern).all? do |forms|
          accepted = forms.respond_to?(:to_a) ? forms.to_a : Array(forms)
          accepted.any? { |character| maybe_includes?(data, character) }
        end
      end

      alternatives ? term_results.any? : term_results.all?
    end

    def maybe_includes?(blob, character)
      unit = character.to_s
      return false unless unit.each_codepoint.one?

      positions_for(unit.ord).all? do |position|
        byte = blob.getbyte(position >> 3)
        byte && (byte & (1 << (position & 7))).positive?
      end
    end

    def positions_for(codepoint)
      HASH_SEEDS.map do |seed|
        mix64(codepoint.to_i ^ seed) % BIT_COUNT
      end
    end
    private_class_method :positions_for

    def mix64(value)
      value &= MASK_64
      value ^= value >> 30
      value = (value * 0xbf58476d1ce4e5b9) & MASK_64
      value ^= value >> 27
      value = (value * 0x94d049bb133111eb) & MASK_64
      value ^ (value >> 31)
    end
    private_class_method :mix64
  end
end
