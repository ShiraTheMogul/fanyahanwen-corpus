# frozen_string_literal: true

module Ids
  class Search
    Result = Struct.new(:structure, :score, :component_score, :operator_score, keyword_init: true)

    def initialize(scope: CharacterStructure.where(system: "ids"))
      @scope = scope
    end

    def exact(query, limit: 50)
      normalized = Parser.normalize(query)
      rows = @scope.where(normalized_expression: normalized)
                   .includes(:character_codepoint, :components)
                   .limit(limit * 3)
                   .map { |structure| Result.new(structure: structure, score: 1.0, component_score: 1.0, operator_score: 1.0) }
      dedupe(rows).first(limit)
    end

    def fuzzy(query, limit: 50, candidate_limit: 1_000)
      normalized = Parser.normalize(query)
      return [] if normalized.blank?

      query_tree = Parser.parse(normalized) rescue nil
      query_leaves = query_tree ? Parser.leaves(query_tree) : Parser.loose_components(normalized)
      query_operators = query_tree ? Parser.operators(query_tree) : Parser.tokens(normalized).select { |token| Parser::OPERATORS.include?(token) }
      return [] if query_leaves.empty?

      # Ask Active Record to merge the already-scoped CharacterStructure relation
      # into the join instead of joining `character_structures` and then adding a
      # second `id IN (SELECT id FROM character_structures ...)` constraint. The
      # latter produced a very expensive SQLite plan in the performance sweep.
      #
      # pluck also returns only the IDs we need; `.count.keys` asked SQLite to
      # materialise the grouped counts back into a Ruby Hash even though the count
      # itself is used only for ORDER BY.
      candidate_ids = CharacterStructureComponent
                      .joins(:character_structure)
                      .merge(@scope)
                      .where(component: query_leaves.uniq)
                      .group(:character_structure_id)
                      .order(Arel.sql("COUNT(*) DESC"))
                      .limit(candidate_limit)
                      .pluck(:character_structure_id)

      structures = @scope.where(id: candidate_ids).includes(:character_codepoint, :components)
      query_top = query_tree && Parser.top_operator(query_tree)

      results = structures.map do |structure|
        candidate_tree = Parser.parse(structure.normalized_expression) rescue nil
        candidate_leaves = candidate_tree ? Parser.leaves(candidate_tree) : structure.components.map(&:component)
        candidate_operators = candidate_tree ? Parser.operators(candidate_tree) : []

        component_score = multiset_jaccard(query_leaves, candidate_leaves)
        operator_score = multiset_jaccard(query_operators, candidate_operators)
        top_bonus = query_top.present? && query_top == structure.top_level_operator ? 1.0 : 0.0
        order_score = sequence_similarity(query_leaves, candidate_leaves)

        score = if query_operators.empty?
                  (component_score * 0.75) + (order_score * 0.25)
                else
                  (component_score * 0.58) + (operator_score * 0.20) + (order_score * 0.12) + (top_bonus * 0.10)
                end

        score = 1.0 if structure.normalized_expression == normalized
        Result.new(structure: structure, score: score, component_score: component_score, operator_score: operator_score)
      end

      sorted = results.sort_by { |result| [-result.score, result.structure.leaf_count, result.structure.character_codepoint.codepoint] }
      dedupe(sorted).first(limit)
    end

    private

    def dedupe(results)
      results.uniq do |result|
        structure = result.structure
        [structure.character_codepoint_id, structure.normalized_expression, structure.glyph_region.to_s]
      end
    end

    def sequence_similarity(left, right)
      max = [left.length, right.length].max
      return 1.0 if max.zero?

      matches = (0...max).count { |index| left[index].present? && left[index] == right[index] }
      matches.to_f / max
    end

    def multiset_jaccard(left, right)
      left_counts = left.tally
      right_counts = right.tally
      keys = left_counts.keys | right_counts.keys
      return 1.0 if keys.empty?

      intersection = keys.sum { |key| [left_counts[key].to_i, right_counts[key].to_i].min }
      union = keys.sum { |key| [left_counts[key].to_i, right_counts[key].to_i].max }
      union.zero? ? 0.0 : intersection.to_f / union
    end
  end
end
