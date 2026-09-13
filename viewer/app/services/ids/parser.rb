# frozen_string_literal: true

module Ids
  class Parser
    class ParseError < StandardError; end

    Node = Struct.new(:token, :children, keyword_init: true) do
      def leaf?
        children.empty?
      end
    end

    UNARY_OPERATORS = ["⿾", "⿿"].freeze
    TRINARY_OPERATORS = ["⿲", "⿳"].freeze
    BINARY_OPERATORS = ["⿰", "⿱", "⿴", "⿵", "⿶", "⿷", "⿸", "⿹", "⿺", "⿻", "⿼", "⿽", "㇯"].freeze
    OPERATORS = (UNARY_OPERATORS + TRINARY_OPERATORS + BINARY_OPERATORS).freeze

    class << self
      def normalize(expression)
        normalized = expression.to_s
          .gsub(/U\+([0-9A-Fa-f]{4,6})/) { [$1.to_i(16)].pack("U") }
          .gsub(/\s+/, "")
          .strip

        # yi-bai/ids lv1/lv2 can qualify an IDC with rendering/selection
        # information, e.g. ⿻[1:] or ⿻[x_]. The qualifier belongs to the
        # source notation, not to the operator's structural arity. Raw source
        # notation remains stored in CharacterStructure metadata.
        operator_chars = Regexp.escape(OPERATORS.join)
        normalized.gsub(/([#{operator_chars}])\[[^\]]*\]/, "\\1")
      rescue RangeError
        expression.to_s.gsub(/\s+/, "").strip
      end

      def parse(expression)
        normalized = normalize(expression)
        raise ParseError, "empty IDS expression" if normalized.empty?

        tokens = tokenize(normalized)
        node, next_index = parse_at(tokens, 0)
        raise ParseError, "extra IDS operands" unless next_index == tokens.length

        node
      end

      def valid?(expression)
        parse(expression)
        true
      rescue ParseError
        false
      end

      def tokens(expression)
        tokenize(normalize(expression))
      end

      def leaves(node)
        return [node.token] if node.leaf?

        node.children.flat_map { |child| leaves(child) }
      end

      def operators(node)
        return [] if node.leaf?

        [node.token] + node.children.flat_map { |child| operators(child) }
      end

      def top_operator(node)
        node.leaf? ? nil : node.token
      end

      def component_rows(node, depth: 0, rows: [], preorder: [0])
        if node.leaf?
          token = node.token
          codepoint = single_unicode_scalar(token)&.ord
          rows << {
            component: token,
            component_codepoint: codepoint,
            depth: depth,
            preorder_index: preorder[0]
          }
          preorder[0] += 1
          return rows
        end

        node.children.each { |child| component_rows(child, depth: depth + 1, rows: rows, preorder: preorder) }
        rows
      end

      def loose_components(expression)
        tokenize(normalize(expression)).reject { |token| OPERATORS.include?(token) }
      end

      # Whether an expression describes a whole character or stops part-way.
      #
      # IDS is Polish notation: the operator comes first and its operands
      # follow, so one counter is enough. Start owing one node; each token
      # pays off one debt and incurs as many as its own arity.
      #
      #   ⿰木目   1 -> ⿰ 0+2=2 -> 木 1 -> 目 0    complete
      #   ⿰木     1 -> ⿰ 0+2=2 -> 木 1            one operand short
      #   ⿰木目目  1 -> ... -> 0, then a token with nothing owed  too many
      #
      # Anything that will not tokenise is reported incomplete rather than
      # raising, so a caller can treat "cannot tell" and "not whole" alike.
      def complete?(expression)
        tokens = tokenize(normalize(expression))
        return false if tokens.empty?

        owed = 1
        tokens.each do |token|
          return false if owed.zero?

          owed += operator_arity(token).to_i - 1
        end
        owed.zero?
      rescue ParseError, StandardError
        false
      end

      private

      def parse_at(tokens, index)
        raise ParseError, "missing IDS operand" if index >= tokens.length

        token = tokens[index]
        arity = operator_arity(token)
        return [Node.new(token: token, children: []), index + 1] unless arity

        children = []
        next_index = index + 1
        arity.times do
          child, next_index = parse_at(tokens, next_index)
          children << child
        end

        [Node.new(token: token, children: children), next_index]
      end

      def operator_arity(token)
        return 1 if UNARY_OPERATORS.include?(token)
        return 3 if TRINARY_OPERATORS.include?(token)
        return 2 if BINARY_OPERATORS.include?(token)

        nil
      end

      # IDS datasets sometimes use entities such as &CDP-xxxx; for components
      # that do not have a convenient encoded character. Treat one entity as
      # one operand rather than splitting it into Latin letters.
      def tokenize(text)
        tokens = []
        rest = text.dup
        until rest.empty?
          if rest.start_with?("&") && (ending = rest.index(";"))
            tokens << rest[0..ending]
            rest = rest[(ending + 1)..] || ""
          elsif rest.start_with?("#(") && (ending = rest.index(")", 2))
            # yi-bai/ids uses #(…) as one special/unencoded graphical
            # component. Keep the whole token as one leaf.
            tokens << rest[0..ending]
            rest = rest[(ending + 1)..] || ""
          else
            match = rest.match(/\A\X/)
            raise ParseError, "invalid Unicode token" unless match

            tokens << match[0]
            rest = rest[match[0].length..] || ""
          end
        end
        tokens
      end

      def single_unicode_scalar(token)
        return nil if token.start_with?("&")

        chars = token.codepoints
        chars.length == 1 ? token : nil
      end
    end
  end
end
