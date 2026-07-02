# frozen_string_literal: true

require "set"

module CorpusSearch
  # Character-aware string operations. Offsets are character indexes, not bytes.
  module SearchText
    module_function

    def chars_for(text_or_chars)
      text_or_chars.is_a?(Array) ? text_or_chars : text_or_chars.to_s.each_char.to_a
    end

    def positions_of(text_or_chars, term_or_chars)
      term_chars = chars_for(term_or_chars)
      positions_of_pattern(
        text_or_chars,
        term_chars.map { |character| Set[character] }
      )
    end

    # Find positions for a pattern where each query unit is a set of accepted
    # source characters. This is the core used by common-variant and broad
    # script-equivalent matching.
    def positions_of_pattern(text_or_chars, pattern)
      chars = chars_for(text_or_chars)
      accepted = Array(pattern)
      return [] if accepted.empty? || chars.empty? || accepted.length > chars.length

      positions = []
      last_start = chars.length - accepted.length
      index = 0

      while index <= last_start
        matched = accepted.each_with_index.all? do |forms, offset|
          forms.include?(chars[index + offset])
        end
        positions << index if matched
        index += 1
      end

      positions
    end

    def count(text, term)
      positions_of(text, term).length
    end
  end
end
