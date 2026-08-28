# frozen_string_literal: true

module CorpusSearch
  # Immutable search meaning. Pagination and snippet presentation live in
  # PresentationOptions so display changes do not redefine a match.
  class SearchDefinition
    SCHEMA_VERSION = 8
    MODES = %w[exact regex proximity alternatives].freeze
    ORDERS = %w[any entered].freeze
    PUNCTUATION_MODES = NormalizedText::PUNCTUATION_MODES
    CHARACTER_EQUIVALENCE_LEVELS = CharacterEquivalenceRegistry::LEVELS
    MAX_MULTI_TERMS = 10
    MAX_PROXIMITY_TERMS = MAX_MULTI_TERMS
    MAX_ALTERNATIVE_TERMS = MAX_MULTI_TERMS
    MAX_REGEX_LENGTH = 1_000

    attr_reader :mode, :query_text, :terms, :maximum_span, :order,
                :punctuation, :character_equivalence, :metadata_filters,
                :document_roles, :include_folders, :exclude_folders, :deduplicate_exact_bodies

    def initialize(mode: "exact", query_text: nil, terms: nil, maximum_span: 200,
                   order: "any", punctuation: "ignore", character_equivalence: "common",
                   metadata_filters: {}, document_roles: nil,
                   include_folders: nil, exclude_folders: nil, deduplicate_exact_bodies: false)
      @mode = MODES.include?(mode.to_s) ? mode.to_s : "exact"
      raw_query_text = query_text.to_s
      # Leading/trailing whitespace can be meaningful regular-expression syntax.
      # Exact-sequence input keeps its existing user-friendly trimming behaviour.
      @query_text = regex? ? raw_query_text : raw_query_text.strip
      @terms = normalize_terms(terms).freeze
      @maximum_span = clamp_integer(maximum_span, default: 200, min: 1, max: 5_000)
      @order = ORDERS.include?(order.to_s) ? order.to_s : "any"
      @punctuation = PUNCTUATION_MODES.include?(punctuation.to_s) ? punctuation.to_s : "ignore"

      # Regex syntax contains characters such as brackets, escapes, and ranges.
      # Expanding individual Han forms inside that syntax would change the
      # expression itself. Regex therefore always searches the exact normalized
      # character stream; variant-aware searches remain available in the other
      # three modes.
      requested_equivalence = CHARACTER_EQUIVALENCE_LEVELS.include?(character_equivalence.to_s) ? character_equivalence.to_s : "common"
      @character_equivalence = regex? ? "exact" : requested_equivalence

      @metadata_filters = normalize_metadata_filters(metadata_filters).freeze
      @document_roles = normalize_roles(document_roles).freeze
      @include_folders = normalize_paths(include_folders).freeze
      @exclude_folders = normalize_paths(exclude_folders).freeze
      @deduplicate_exact_bodies = truthy?(deduplicate_exact_bodies)
      freeze
    end

    def exact? = @mode == "exact"
    def regex? = @mode == "regex"
    def proximity? = @mode == "proximity"
    def alternatives? = @mode == "alternatives"
    def single_term? = exact? || regex?
    def multi_term? = proximity? || alternatives?
    def ignore_punctuation? = @punctuation == "ignore"
    def deduplicate_exact_bodies? = @deduplicate_exact_bodies

    def effective_terms
      single_term? ? [@query_text] : @terms
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
        "query_text" => single_term? ? @query_text : nil,
        "terms" => multi_term? ? @terms : nil,
        "proximity" => proximity? ? {
          "maximum_span" => @maximum_span,
          "order" => @order
        } : nil,
        "matching" => {
          "punctuation" => @punctuation,
          "character_equivalence" => @character_equivalence,
          "character_equivalence_version" => CharacterEquivalenceRegistry.version_for(@character_equivalence),
          "normalization_profile_version" => NormalizationProfile.current.version
        },
        "scope" => {
          "document_roles" => @document_roles,
          "include_folders" => @include_folders,
          "exclude_folders" => @exclude_folders,
          "deduplicate_exact_bodies" => @deduplicate_exact_bodies
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

    def truthy?(value)
      value == true || %w[1 true yes on].include?(value.to_s.downcase)
    end

    def clamp_integer(value, default:, min:, max:)
      integer = Integer(value)
      [[integer, min].max, max].min
    rescue ArgumentError, TypeError
      default
    end
  end
end
