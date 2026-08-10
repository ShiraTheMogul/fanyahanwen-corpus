# frozen_string_literal: true

module CharacterData
  # The character database is intentionally script-neutral.
  #
  # CharacterCodepoint stores one Unicode scalar value in an integer `codepoint`
  # column and its literal glyph in `chr`. That means the admission rule should
  # describe what the table can faithfully represent, not try to decide whether
  # a glyph is "Han enough" to deserve a page.
  #
  # This deliberately admits Han, CJK radicals/strokes, kana, Hangul, symbols
  # used as graphical components, Latin, and other scripts. Source-specific
  # importers remain responsible for deciding whether a row belongs in their
  # dataset.
  module IndexableCharacter
    module_function

    def single?(text)
      string = text.to_s
      codepoints = string.codepoints
      return false unless codepoints.length == 1

      # Do not create pages for whitespace/control characters. Unassigned and
      # project-reserved scalar values are allowed because Fanya already uses a
      # reserved range for seal-script work.
      !string.match?(/\A[\p{Cc}\p{Z}]\z/u)
    rescue ArgumentError, Encoding::CompatibilityError
      false
    end

    def codepoint?(codepoint)
      cp = Integer(codepoint)
      return false unless cp.between?(0, 0x10FFFF)
      return false if cp.between?(0xD800, 0xDFFF) # UTF-16 surrogate range

      single?([cp].pack("U"))
    rescue ArgumentError, RangeError, TypeError
      false
    end

    def each_char(text)
      return enum_for(:each_char, text) unless block_given?

      text.to_s.each_char do |char|
        yield char if single?(char)
      end
    end

    def codepoints(text)
      each_char(text).map(&:ord)
    end
  end
end
