# frozen_string_literal: true

module CorpusSearch
  # Immutable search meaning. Pagination and snippet presentation live in
  # PresentationOptions so display changes do not redefine a match.
  class SearchDefinition
    SCHEMA_VERSION = 4
    MODES = %w[exact proximity].freeze
    ORDERS = %w[any entered].freeze
    PUNCTUATION_MODES = NormalizedText::PUNCTUATION_MODES
    CHARACTER_EQUIVALENCE_LEVELS = %w[exact common broad].freeze
    MAX_PROXIMITY_TERMS = 10
    IMPLEMENTED_CHARACTER_EQUIVALENCE_LEVELS = %w[exact].freeze

    attr_reader :mode, :query_text, :terms, :maximum_span, :order,
                :punctuation, :character_equivalence, :metadata_filters,
                :document_roles, :include_folders, :exclude_folders

    def initialize(mode: "exact", query_text: nil, terms: nil, maximum_span: 200,
                   order: "any", punctuation: "ignore", character_equivalence: "exact",
                   metadata_filters: {}, document_roles: nil,
                   include_folders: nil, exclude_folders: nil)
      @mode = MODES.include?(mode.to_s) ? mode.to_s : "exact"
      @query_text = query_text.to_s.strip
      @terms = normalize_terms(terms).freeze
      @maximum_span = clamp_integer(maximum_span, default: 200, min: 1, max: 5_000)
      @order = ORDERS.include?(order.to_s) ? order.to_s : "any"
      @punctuation = PUNCTUATION_MODES.include?(punctuation.to_s) ? punctuation.to_s : "ignore"
      @character_equivalence = IMPLEMENTED_CHARACTER_EQUIVALENCE_LEVELS.include?(character_equivalence.to_s) ? character_equivalence.to_s : "exact"
      @metadata_filters = normalize_metadata_filters(metadata_filters).freeze
      @document_roles = normalize_roles(document_roles).freeze
      @include_folders = normalize_paths(include_folders).freeze
      @exclude_folders = normalize_paths(exclude_folders).freeze
      freeze
    end

    def exact? = @mode == "exact"
    def proximity? = @mode == "proximity"
    def ignore_punctuation? = @punctuation == "ignore"

    def effective_terms
      exact? ? [@query_text] : @terms
    end

    def manifest_filters
      @metadata_filters.merge(
        "document_roles" => @document_roles,
        "include_folders" => @include_folders,
        "exclude_folders" => @exclude_folders
      )
    end

    def to_h
      {
        "schema_version" => SCHEMA_VERSION,
        "mode" => @mode,
        "query_text" => exact? ? @query_text : nil,
        "terms" => proximity? ? @terms : nil,
        "proximity" => proximity? ? {
          "maximum_span" => @maximum_span,
          "order" => @order
        } : nil,
        "matching" => {
          "punctuation" => @punctuation,
          "character_equivalence" => @character_equivalence,
          "normalization_profile_version" => NormalizationProfile.current.version
        },
        "scope" => {
          "document_roles" => @document_roles,
          "include_folders" => @include_folders,
          "exclude_folders" => @exclude_folders
        },
        "metadata_filters" => @metadata_filters.reject { |_key, value| value.blank? }
      }.compact
    end

    private

    def normalize_terms(values)
      Array(values).map { |value| value.to_s.strip }.reject(&:empty?)
    end

    def normalize_metadata_filters(filters)
      filters.to_h.transform_keys(&:to_s).transform_values { |value| value.to_s.strip }
    end

    def normalize_roles(values)
      selected = Array(values).flat_map { |value| value.to_s.split(",") }
        .map(&:strip)
        .select { |role| DocumentRole::SEARCHABLE_ROLES.include?(role) }
        .uniq

      return DocumentRole::DEFAULT_ROLES.dup if selected.empty?

      DocumentRole::SEARCHABLE_ROLES.select { |role| selected.include?(role) }
    end

    def normalize_paths(values)
      Array(values).flat_map { |value| value.to_s.split("\n") }
        .map { |path| path.strip.tr("\\", "/").sub(%r{\A/+}, "").sub(%r{/+\z}, "") }
        .reject(&:empty?)
        .uniq
        .sort
    end

    def clamp_integer(value, default:, min:, max:)
      integer = Integer(value)
      [[integer, min].max, max].min
    rescue ArgumentError, TypeError
      default
    end
  end
end
