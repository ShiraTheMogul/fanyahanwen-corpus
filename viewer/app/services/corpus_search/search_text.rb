# frozen_string_literal: true

module CorpusSearch
  # Character-aware string operations. Offsets are character indexes, not bytes.
  module SearchText
    module_function

    def chars_for(text_or_chars)
      text_or_chars.is_a?(Array) ? text_or_chars : text_or_chars.to_s.each_char.to_a
    end

    def positions_of(text_or_chars, term_or_chars)
      chars = chars_for(text_or_chars)
      term_chars = chars_for(term_or_chars)
      return [] if term_chars.empty? || chars.empty? || term_chars.length > chars.length

      positions = []
      last_start = chars.length - term_chars.length
      index = 0

      while index <= last_start
        positions << index if chars[index, term_chars.length] == term_chars
        index += 1
      end

      positions
    end

    def count(text, term)
      positions_of(text, term).length
    end
  end
end
