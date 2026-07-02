# frozen_string_literal: true

module CorpusSearch
  # Immutable search meaning. Pagination and snippet presentation deliberately
  # live elsewhere so later UI changes do not redefine what counts as a match.
  class SearchDefinition
    SCHEMA_VERSION = 2
    MODES = %w[exact proximity].freeze
    ORDERS = %w[either a_before_b b_before_a].freeze

    attr_reader :mode, :term_a, :term_b, :distance, :order, :metadata_filters,
                :document_roles, :include_folders, :exclude_folders

    def initialize(mode: "exact", term_a: nil, term_b: nil, distance: 200,
                   order: "either", metadata_filters: {}, document_roles: nil,
                   include_folders: nil, exclude_folders: nil)
      @mode = MODES.include?(mode.to_s) ? mode.to_s : "exact"
      @term_a = term_a.to_s.strip
      @term_b = term_b.to_s.strip
      @distance = clamp_integer(distance, default: 200, min: 1, max: 5_000)
      @order = ORDERS.include?(order.to_s) ? order.to_s : "either"
      @metadata_filters = normalize_metadata_filters(metadata_filters).freeze
      @document_roles = normalize_roles(document_roles).freeze
      @include_folders = normalize_paths(include_folders).freeze
      @exclude_folders = normalize_paths(exclude_folders).freeze
      freeze
    end

    def proximity?
      @mode == "proximity"
    end

    def exact?
      @mode == "exact"
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
        "terms" => [@term_a, (@term_b if proximity?)].compact,
        "proximity" => proximity? ? {
          "maximum_span" => @distance,
          "order" => @order
        } : nil,
        "scope" => {
          "document_roles" => @document_roles,
          "include_folders" => @include_folders,
          "exclude_folders" => @exclude_folders
        },
        "metadata_filters" => @metadata_filters.reject { |_key, value| value.blank? }
      }.compact
    end

    private

    def normalize_metadata_filters(filters)
      filters.to_h.transform_keys(&:to_s).transform_values { |value| value.to_s.strip }
    end

    def normalize_roles(values)
      selected = Array(values).flat_map { |value| value.to_s.split(",") }
        .map(&:strip)
        .select { |role| DocumentRole::SEARCHABLE_ROLES.include?(role) }
        .uniq

      selected.presence || DocumentRole::DEFAULT_ROLES.dup
    end

    def normalize_paths(values)
      Array(values).flat_map { |value| value.to_s.split("\n") }
        .map { |path| path.strip.tr("\\", "/").sub(%r{\A/+}, "").sub(%r{/+\z}, "") }
        .reject(&:empty?)
        .uniq
    end

    def clamp_integer(value, default:, min:, max:)
      integer = Integer(value)
      [[integer, min].max, max].min
    rescue ArgumentError, TypeError
      default
    end
  end
end
