# frozen_string_literal: true

require "set"

module CorpusSearch
  # Character-aware string operations. Public offsets are character indexes.
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
    #
    # When Runner supplies a NormalizedText object, literal patterns search the
    # complete sequence with String#byteindex. Variant-aware patterns pick the
    # smallest character-equivalence class as the byte-search anchor, then verify
    # only those candidate positions in Ruby. Byte offsets are converted back to
    # the corpus's character-offset contract in one forward pass over the slices
    # between matches. This avoids String#index repeatedly walking from the start
    # of a UTF-8 string to translate character offsets on dense Han queries.
    #
    # Design influence: Notepad++ Find in Files keeps the hot search loop inside
    # its native matcher and reuses prepared search state across many files. See
    # Ho, D. (with Notepad++ contributors), Notepad++, and in particular
    # FindReplaceDlg.cpp / BoostRegExSearch.cxx at commit c057c08028b4d40490c6e21bf87a18e95cc3e318.
    # This is an independent Ruby implementation; no GPL source is copied.
    def positions_of_pattern(text_or_chars, pattern)
      accepted = Array(pattern)
      return [] if accepted.empty?

      if normalized_searchable?(text_or_chars) && single_character_pattern?(accepted)
        return positions_of_literal_in_normalized(text_or_chars, accepted) if literal_pattern?(accepted)

        return positions_of_pattern_in_normalized(text_or_chars, accepted)
      end

      chars = chars_for(text_or_chars)
      positions_of_pattern_in_chars(chars, accepted)
    end

    def positions_of_literal_in_normalized(searchable, accepted)
      chars = searchable.units
      return [] if chars.empty? || accepted.length > chars.length

      literal = accepted.map { |forms| forms.first.to_s }.join
      return [] if literal.empty?

      byte_positions = byte_positions_of_literal(searchable.text, literal)
      character_offsets_for_byte_offsets(searchable.text, byte_positions)
    end

    def positions_of_pattern_in_normalized(searchable, accepted)
      chars = searchable.units
      return [] if chars.empty? || accepted.length > chars.length

      anchor_index, anchor_forms = best_anchor(accepted)
      return positions_of_pattern_in_chars(chars, accepted) if anchor_forms.nil? || anchor_forms.empty?

      anchor_byte_positions = anchor_forms.flat_map do |form|
        needle = form.to_s
        needle.empty? ? [] : byte_positions_of_literal(searchable.text, needle)
      end
      anchor_byte_positions.sort!.uniq!
      anchor_positions = character_offsets_for_byte_offsets(searchable.text, anchor_byte_positions)

      last_start = chars.length - accepted.length
      positions = anchor_positions.filter_map do |anchor_position|
        search_start = anchor_position - anchor_index
        next if search_start.negative? || search_start > last_start
        next unless pattern_matches_at?(chars, accepted, search_start)

        search_start
      end

      positions.uniq
    end

    # String#byteindex can resume from a byte offset without repeatedly converting
    # a UTF-8 character offset from the start of the string. Advance by the first
    # matched character's byte width so overlapping sequence matches are retained.
    def byte_positions_of_literal(text, literal)
      first_character = literal.each_char.first
      return [] unless first_character

      step = first_character.bytesize
      positions = []
      byte_offset = 0
      while (candidate = text.byteindex(literal, byte_offset))
        positions << candidate
        byte_offset = candidate + step
      end
      positions
    end

    # Convert sorted byte offsets to UTF-8 character offsets. Each slice starts at
    # the previous match and ends at the next one, so the total decoded prefix is
    # traversed at most once even when a common character has many occurrences.
    def character_offsets_for_byte_offsets(text, byte_offsets)
      character_offsets = []
      byte_cursor = 0
      character_cursor = 0

      byte_offsets.each do |byte_offset|
        if byte_offset > byte_cursor
          character_cursor += text.byteslice(byte_cursor, byte_offset - byte_cursor).length
          byte_cursor = byte_offset
        end
        character_offsets << character_cursor
      end

      character_offsets
    end

    def character_ranges_for_byte_ranges(text, byte_ranges)
      endpoints = byte_ranges.flatten.uniq.sort
      characters = character_offsets_for_byte_offsets(text, endpoints)
      endpoint_map = endpoints.zip(characters).to_h
      byte_ranges.map { |start_byte, end_byte| [endpoint_map.fetch(start_byte), endpoint_map.fetch(end_byte)] }
    end

    def positions_of_pattern_in_chars(chars, accepted)
      return [] if accepted.empty? || chars.empty? || accepted.length > chars.length

      positions = []
      last_start = chars.length - accepted.length
      first_forms = accepted.first
      pattern_length = accepted.length
      index = 0

      # Gate on the first unit, then use a simple while loop for positions that
      # remain candidates. This remains the safe fallback for callers that pass
      # an array or plain string without NormalizedText's prepared text string.
      while index <= last_start
        unless first_forms.include?(chars[index])
          index += 1
          next
        end

        positions << index if pattern_matches_at?(chars, accepted, index)
        index += 1
      end

      positions
    end

    def pattern_matches_at?(chars, accepted, start_index)
      offset = 0
      pattern_length = accepted.length
      while offset < pattern_length && accepted[offset].include?(chars[start_index + offset])
        offset += 1
      end
      offset == pattern_length
    end

    def best_anchor(accepted)
      accepted.each_with_index.min_by { |forms, index| [forms.length, index] }&.then do |forms, index|
        [index, forms]
      end
    end

    def literal_pattern?(accepted)
      accepted.all? { |forms| forms.length == 1 }
    end

    def single_character_pattern?(accepted)
      accepted.all? do |forms|
        forms.respond_to?(:all?) && forms.all? { |form| form.to_s.each_char.count == 1 }
      end
    end

    def normalized_searchable?(value)
      value.respond_to?(:units) && value.respond_to?(:text)
    end

    def count(text, term)
      positions_of(text, term).length
    end
  end
end
