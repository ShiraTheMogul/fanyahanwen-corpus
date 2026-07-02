# frozen_string_literal: true

module CorpusSearch
  # Describes one reproducible two-scope comparison. It changes only the
  # analytical grouping; the underlying text query remains identical.
  class ComparisonDefinition
    DIMENSIONS = %w[period nation region folder document_role].freeze

    attr_reader :dimension, :left_group, :right_group

    def self.from_params(params)
      source = if params.respond_to?(:to_unsafe_h)
        params.to_unsafe_h
      else
        params.to_h
      end
      source = source.stringify_keys
      source = source.fetch("comparison", source).to_h.stringify_keys

      new(
        dimension: source["dimension"],
        left_group: source["left_group"],
        right_group: source["right_group"]
      )
    end

    def self.from_h(hash)
      source = hash.to_h.stringify_keys
      new(
        dimension: source["dimension"],
        left_group: source["left_group"],
        right_group: source["right_group"]
      )
    end

    def initialize(dimension:, left_group:, right_group:)
      @dimension = dimension.to_s.strip
      @left_group = left_group.to_s.strip
      @right_group = right_group.to_s.strip
      freeze
    end

    def requested?
      dimension.present? || left_group.present? || right_group.present?
    end

    def valid?
      errors.empty?
    end

    def errors
      list = []
      return list unless requested?

      list << I18n.t("corpus_search.comparison.errors.dimension") unless DIMENSIONS.include?(dimension)
      list << I18n.t("corpus_search.comparison.errors.left_group") if left_group.blank?
      list << I18n.t("corpus_search.comparison.errors.right_group") if right_group.blank?
      list << I18n.t("corpus_search.comparison.errors.distinct") if left_group.present? && left_group == right_group
      list
    end

    def to_h
      {
        "version" => 1,
        "dimension" => dimension,
        "left_group" => left_group,
        "right_group" => right_group
      }
    end

    def display_label
      "#{left_group} ↔ #{right_group}"
    end
  end
end
