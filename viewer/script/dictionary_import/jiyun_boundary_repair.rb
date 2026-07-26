# frozen_string_literal: true

require_relative "parsers"

module DictionaryImport
  module Parsers
    # Repairs two recurring, source-backed 集韻 layouts without changing the
    # shared parser rules used by other dictionaries:
    #
    #   〈previous definition〉○千
    #   〈倉先切...〉仟
    #
    # Here 千 is a real numeral headword, not a count or heading.
    #
    #   〈previous definition〉○
    #   〈初佳切...〉叉
    #
    # Here the group head is printed after its first payload. The generic parser
    # cannot attach it because it sees the payload before the head. We reorder
    # that one physical line for parsing only; source text and line ranges remain
    # unchanged in the emitted record.
    module JiyunBoundaryRepair
      def allow_numeral_heads_in_separator_tail? = true

      def process_entry_line(raw, source_map, entries, warnings, metrics)
        rewritten = reorder_postposed_head_after_bare_boundary(raw)
        return super unless rewritten

        before_count = entries.length
        super(rewritten, source_map, entries, warnings, metrics)
        recovered = entries[before_count]
        return unless recovered

        recovered["source_structure_notes"] = Array(recovered["source_structure_notes"])
        recovered["source_structure_notes"] << "postposed_group_head_reordered_for_parse"
      end

      private

      def reorder_postposed_head_after_bare_boundary(raw)
        return nil unless @pending_group_boundary

        tokens = tokenize(raw)
        return nil unless tokens.length == 2
        return nil unless tokens[0].fetch(:type) == :payload
        return nil unless tokens[1].fetch(:type) == :outside

        tail = tokens[1].fetch(:value).to_s
        return nil if tail.include?("○")

        extracted = extract_heads(tail)
        return nil unless extracted

        "#{tail}〈#{tokens[0].fetch(:value)}〉"
      end
    end
  end
end

DictionaryImport::Parsers::Jiyun.prepend(DictionaryImport::Parsers::JiyunBoundaryRepair)
