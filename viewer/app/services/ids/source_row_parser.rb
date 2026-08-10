# frozen_string_literal: true

module Ids
  # Parse the row grammar documented by yi-bai/ids.
  #
  # Each data row is:
  #   character<TAB>primary IDSes<TAB>alternative IDSes
  #
  # The two IDS columns are semicolon-separated lists. A semicolon may also
  # terminate an entity operand such as &CDP-8BF5;, so String#split(";") is not
  # safe here. Each IDS can end in comma-separated variant indicators inside
  # parentheses.
  class SourceRowParser
    Row = Struct.new(:codepoint, :glyph, :candidates, keyword_init: true)
    Candidate = Struct.new(
      :expression,
      :raw_expression,
      :list_type,
      :field_index,
      :indicators,
      :annotations,
      keyword_init: true
    )

    class ParseError < StandardError; end

    # Yi Bai's lv0 notation attaches compact rendering/stroke qualifiers to
    # operands.  zi.tools' public zi-assets splitter uses this exact modifier
    # alphabet when separating structural components from source notation.
    # These are metadata, not IDS operands, so they must never enter search.
    OPERAND_MODIFIER_CHARS = ".0123456789BGHJKMPQSTUVabcdefghjlmnpqrstuvwxyz".freeze
    OPERAND_MODIFIER_SET = OPERAND_MODIFIER_CHARS.each_char.to_h { |char| [char, true] }.freeze

    def parse(line)
      text = line.to_s.delete_prefix("\uFEFF").chomp
      return nil if ignorable?(text)

      fields = text.split("\t", -1)
      raise ParseError, "expected at least 2 tab-separated columns" if fields.length < 2

      glyph = fields[0].to_s.strip
      raise ParseError, "first column is not one indexable character: #{glyph.inspect}" unless valid_subject?(glyph)

      candidates = []
      fields.drop(1).each_with_index do |field, offset|
        field_index = offset + 1
        list_type = case field_index
                    when 1 then "primary"
                    when 2 then "alternative"
                    else "extra"
                    end

        split_alternatives(field).each do |raw_candidate|
          candidate = parse_candidate(raw_candidate, list_type: list_type, field_index: field_index)
          candidates << candidate if candidate
        end
      end

      Row.new(codepoint: glyph.ord, glyph: glyph, candidates: candidates)
    end

    private

    def ignorable?(text)
      stripped = text.strip
      stripped.empty? || stripped.start_with?("#")
    end

    def valid_subject?(text)
      CharacterData::IndexableCharacter.single?(text) && !Parser::OPERATORS.include?(text)
    end

    def split_alternatives(field)
      alternatives = []
      buffer = +""
      in_entity = false
      nesting = Hash.new(0)
      chars = field.to_s.each_char.to_a
      index = 0

      while index < chars.length
        char = chars[index]

        if in_entity
          buffer << char
          in_entity = false if char == ";"
          index += 1
          next
        end

        if char == "&"
          in_entity = true
          buffer << char
          index += 1
          next
        end

        case char
        when "(" then nesting[:parenthesis] += 1
        when ")" then nesting[:parenthesis] -= 1 if nesting[:parenthesis].positive?
        when "[" then nesting[:bracket] += 1
        when "]" then nesting[:bracket] -= 1 if nesting[:bracket].positive?
        when "{" then nesting[:brace] += 1
        when "}" then nesting[:brace] -= 1 if nesting[:brace].positive?
        end

        top_level = nesting.values.all?(&:zero?)

        if char == ";" && top_level
          append_alternative(alternatives, buffer)
          buffer = +""
          index += 1
          next
        end

        if char.match?(/\s/) && top_level
          run_end = index
          run_end += 1 while run_end < chars.length && chars[run_end].match?(/\s/)
          whitespace = chars[index...run_end].join

          # yi-bai/ids uses two or more spaces as another alternative
          # delimiter in a small number of component rows. A single space is
          # harmless inside an IDS because Parser.normalize removes it.
          if whitespace.length >= 2
            append_alternative(alternatives, buffer)
            buffer = +""
          else
            buffer << whitespace
          end
          index = run_end
          next
        end

        buffer << char
        index += 1
      end

      append_alternative(alternatives, buffer)
      alternatives
    end

    def append_alternative(alternatives, buffer)
      value = buffer.to_s.strip
      alternatives << value unless value.empty?
    end

    def parse_candidate(raw_candidate, list_type:, field_index:)
      raw = raw_candidate.to_s.strip
      return nil if raw.empty?

      indicators = []
      annotations = []
      expression = raw

      # A trailing parenthesised group is Yi Bai's regional/glyph indicator,
      # e.g. (.,T). Do not confuse it with a structural #(…) operand.
      if (match = expression.match(/\A(.*)\(([^()]*)\)\s*\z/m))
        prefix = match[1].to_s
        unless prefix.end_with?("#")
          expression = prefix.strip
          indicators = match[2].to_s.split(",").map(&:strip).reject(&:empty?)
        end
      end

      expression = strip_source_notation(expression, annotations)
      return nil if expression.empty?

      Candidate.new(
        expression: expression,
        raw_expression: raw,
        list_type: list_type,
        field_index: field_index,
        indicators: indicators,
        annotations: annotations
      )
    end

    # Convert Yi Bai's source notation into the functional IDS expression used
    # by Parser/Search while retaining the removed information as metadata.
    #
    # Examples:
    #   ⿱一.亅              -> ⿱一亅
    #   ⿻乚w一.(T)          -> ⿻乚一       (w and . retained as annotations)
    #   ⿺⿻[b]㇉一.一(J)     -> ⿺⿻㇉一一    ([b] retained as annotation)
    #   {丗}⿱卅s一.(T)      -> ⿱卅一
    #
    # This follows the same boundary Yi Bai/zi.tools tooling uses: suffix
    # letters/dots/digits qualify the preceding graphical operand; braces and
    # IDC brackets qualify source/rendering choices. None are tree operands.
    def strip_source_notation(source, annotations)
      out = +""
      chars = source.to_s.each_char.to_a
      index = 0

      while index < chars.length
        char = chars[index]

        if char == "{"
          closing = find_closing(chars, index + 1, "}")
          if closing
            value = chars[(index + 1)...closing].join
            annotations << value unless value.empty?
            index = closing + 1
            next
          end
        end

        if Parser::OPERATORS.include?(char)
          out << char
          index += 1

          if chars[index] == "["
            closing = find_closing(chars, index + 1, "]")
            if closing
              value = chars[(index + 1)...closing].join
              annotations << "[#{value}]" unless value.empty?
              index = closing + 1
            end
          end
          next
        end

        if char == "&"
          closing = find_closing(chars, index + 1, ";")
          if closing
            out << chars[index..closing].join
            index = closing + 1
            index = consume_operand_modifiers(chars, index, annotations)
            next
          end
        end

        if char == "#" && chars[index + 1] == "("
          closing = find_closing(chars, index + 2, ")")
          if closing
            out << chars[index..closing].join
            index = closing + 1
            index = consume_operand_modifiers(chars, index, annotations)
            next
          end
        end

        # Ordinary encoded component. The modifier alphabet is ASCII-only, so
        # one Unicode scalar/grapheme is the structural leaf and any following
        # modifier run belongs to that leaf.
        out << char
        index += 1
        index = consume_operand_modifiers(chars, index, annotations) unless char.match?(/\s/)
      end

      out.strip
    end

    def consume_operand_modifiers(chars, index, annotations)
      buffer = +""
      while index < chars.length && OPERAND_MODIFIER_SET[chars[index]]
        buffer << chars[index]
        index += 1
      end
      annotations << buffer unless buffer.empty?
      index
    end

    def find_closing(chars, index, closing_char)
      while index < chars.length
        return index if chars[index] == closing_char
        index += 1
      end
      nil
    end

  end
end
