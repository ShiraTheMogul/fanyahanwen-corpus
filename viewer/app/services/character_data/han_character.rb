# frozen_string_literal: true

module CharacterData
  # Unicode-17 Script=Han repertoire plus Fanya's explicitly reserved project
  # range. This is classification metadata, not the gate for whether a glyph is
  # allowed to have a CharacterCodepoint row; use IndexableCharacter for that.
  #
  # Keeping this table explicit avoids depending on the Unicode version bundled
  # with the Ruby runtime, which can lag the datasets being imported.
  module HanCharacter
    SCRIPT_RANGES = [
      (0x2E80..0x2E99),   # CJK Radicals Supplement
      (0x2E9B..0x2EF3),   # CJK Radicals Supplement
      (0x2F00..0x2FD5),   # Kangxi Radicals
      (0x3021..0x3029),   # Suzhou numerals 1-9 (Unicode names retain HANGZHOU)
      (0x3038..0x303A),   # Suzhou numerals 10-30 (same Unicode naming legacy)
      (0x3400..0x4DBF),   # Extension A
      (0x4E00..0x9FFF),   # Unified Ideographs
      (0xF900..0xFA6D),   # Compatibility Ideographs
      (0xFA70..0xFAD9),   # Compatibility Ideographs
      (0x16FF0..0x16FF6), # Han reading marks / small forms / yangqin signs
      (0x20000..0x2A6DF), # Extension B
      (0x2A700..0x2B81D), # Extensions C-D and assigned intervening repertoire
      (0x2B820..0x2CEAD), # Extension E
      (0x2CEB0..0x2EBE0), # Extension F
      (0x2EBF0..0x2EE5D), # Extension I
      (0x2F800..0x2FA1D), # Compatibility Ideographs Supplement
      (0x30000..0x3134A), # Extension G
      (0x31350..0x33479)  # Extensions H and J (Unicode 17.0)
    ].freeze

    SCRIPT_SINGLETONS = [
      0x3005, # IDEOGRAPHIC ITERATION MARK
      0x3007, # IDEOGRAPHIC NUMBER ZERO
      0x303B, # VERTICAL IDEOGRAPHIC ITERATION MARK
      0x16FE2, # OLD CHINESE HOOK MARK
      0x16FE3  # OLD CHINESE ITERATION MARK
    ].freeze

    # Reserved by the Fanya project for seal-script character work. This is
    # intentionally separate from the published Unicode-17 Han repertoire.
    PROJECT_RANGES = [
      (0x3D000..0x3FC3F)
    ].freeze

    module_function

    def codepoint?(codepoint, include_project: true)
      cp = Integer(codepoint)
      return true if SCRIPT_SINGLETONS.include?(cp)
      return true if SCRIPT_RANGES.any? { |range| range.cover?(cp) }

      include_project && PROJECT_RANGES.any? { |range| range.cover?(cp) }
    rescue ArgumentError, TypeError
      false
    end

    def single?(text, include_project: true)
      string = text.to_s
      codepoints = string.codepoints
      codepoints.length == 1 && codepoint?(codepoints.first, include_project: include_project)
    end

    def each_char(text, include_project: true)
      return enum_for(:each_char, text, include_project: include_project) unless block_given?

      text.to_s.each_char do |char|
        yield char if codepoint?(char.ord, include_project: include_project)
      end
    end

    def codepoints(text, include_project: true)
      each_char(text, include_project: include_project).map(&:ord)
    end
  end
end
