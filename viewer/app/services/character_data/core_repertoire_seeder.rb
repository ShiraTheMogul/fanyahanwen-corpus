# frozen_string_literal: true

module CharacterData
  # Preload character families that Fanya needs even when a particular data
  # source has not happened to mention them yet.
  #
  # CharacterCodepoint remains the one canonical registry. This service does
  # not create a parallel Kana/Hangul/numeral table; it only ensures that the
  # relevant Unicode scalar values have ordinary CharacterCodepoint rows.
  class CoreRepertoireSeeder
    Result = Struct.new(:characters, :created, :existing, :by_repertoire, keyword_init: true)

    SUZHOU_NUMERALS = [
      0x3007,             # 〇
      *(0x3021..0x3029),  # 〡..〩
      *(0x3038..0x303A)   # 〸..〺
    ].freeze

    COUNTING_ROD_NUMERALS = (0x1D360..0x1D371).to_a.freeze
    TALLY_MARKS = (0x1D372..0x1D378).to_a.freeze

    # Unicode 17 Script=Hiragana/Katakana ranges, plus the shared Kana marks
    # needed to represent ordinary and historical Kana faithfully.
    KANA = [
      *(0x3041..0x3096),
      *(0x309D..0x309F),
      *(0x30A1..0x30FA),
      *(0x30FD..0x30FF),
      *(0x31F0..0x31FF),
      *(0x32D0..0x32FE),
      *(0x3300..0x3357),
      *(0xFF66..0xFF6F),
      *(0xFF71..0xFF9D),
      *(0x1AFF0..0x1AFF3),
      *(0x1AFF5..0x1AFFB),
      *(0x1AFFD..0x1AFFE),
      0x1B000,
      *(0x1B001..0x1B11F),
      *(0x1B120..0x1B122),
      0x1B132,
      *(0x1B150..0x1B152),
      0x1B155,
      *(0x1B164..0x1B167),
      0x1F200,
      *(0x3031..0x3035),
      0x303C,
      0x303D,
      *(0x3099..0x309C),
      0x30A0,
      0x30FB,
      0x30FC,
      0xFF70,
      0xFF9E,
      0xFF9F
    ].uniq.freeze

    # Unicode 17 Script=Hangul repertoire: conjoining and compatibility Jamo,
    # archaic extensions, precomposed syllables, tone marks, and encoded
    # compatibility/enclosed forms.
    HANGUL = [
      *(0x1100..0x11FF),
      *(0x302E..0x302F),
      *(0x3131..0x318E),
      *(0x3200..0x321E),
      *(0x3260..0x327E),
      *(0xA960..0xA97C),
      *(0xAC00..0xD7A3),
      *(0xD7B0..0xD7C6),
      *(0xD7CB..0xD7FB),
      *(0xFFA0..0xFFBE),
      *(0xFFC2..0xFFC7),
      *(0xFFCA..0xFFCF),
      *(0xFFD2..0xFFD7),
      *(0xFFDA..0xFFDC)
    ].freeze

    REPERTOIRES = {
      suzhou_numerals: SUZHOU_NUMERALS,
      counting_rod_numerals: COUNTING_ROD_NUMERALS,
      tally_marks: TALLY_MARKS,
      kana: KANA,
      hangul: HANGUL
    }.freeze

    class << self
      def codepoints_for(repertoire)
        REPERTOIRES.fetch(repertoire.to_sym)
      end

      def all_codepoints
        @all_codepoints ||= REPERTOIRES.values.flatten.uniq.freeze
      end
    end

    def seed(repertoires: REPERTOIRES.keys)
      names = Array(repertoires).map(&:to_sym)
      unknown = names - REPERTOIRES.keys
      raise ArgumentError, "unknown core repertoire(s): #{unknown.join(', ')}" if unknown.any?

      by_repertoire = names.to_h { |name| [name, REPERTOIRES.fetch(name).length] }
      codepoints = names.flat_map { |name| REPERTOIRES.fetch(name) }.uniq
      created = 0

      ActiveRecord::Base.transaction do
        codepoints.each do |codepoint|
          row = CodepointResolver.resolve(codepoint: codepoint)
          created += 1 if row.previously_new_record?
        end
      end

      Result.new(
        characters: codepoints.length,
        created: created,
        existing: codepoints.length - created,
        by_repertoire: by_repertoire
      )
    end
  end
end
