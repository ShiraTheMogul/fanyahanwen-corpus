# frozen_string_literal: true

module CorpusSearch
  # The boundary between GET parameters and the search domain objects. The
  # controller should not know how individual query fields are normalised.
  class QueryParams
    METADATA_KEYS = %w[nation polity period region author year_start year_end].freeze

    class << self
      def parse(params = nil, locale: I18n.locale, **keyword_params)
        source = source_hash(params, keyword_params)

        definition = SearchDefinition.new(
          mode: source["mode"],
          query_text: source["q"],
          terms: array_value(source["terms"]),
          maximum_span: source["span"],
          order: source["order"],
          punctuation: source["punctuation"],
          character_equivalence: source["characters"],
          metadata_filters: METADATA_KEYS.to_h { |key| [key, source[key]] },
          document_roles: array_value(source["roles"]),
          include_folders: array_value(source["folders"]),
          exclude_folders: array_value(source["exclude_folders"]),
          deduplicate_exact_bodies: source["deduplicate"]
        )

        presentation = PresentationOptions.new(
          context: source["context"],
          page: source["page"],
          per_page: source["per_page"]
        )

        Query.new(
          search_definition: definition,
          presentation_options: presentation,
          locale: locale,
          requested: search_requested?(source)
        )
      end

      def search_requested?(params = nil, **keyword_params)
        source = source_hash(params, keyword_params)
        source["q"].present? || array_value(source["terms"]).any? || source["search"].present?
      end

      private

      def source_hash(params, keyword_params)
        positional = if params.nil?
          {}
        elsif params.respond_to?(:to_unsafe_h)
          params.to_unsafe_h
        else
          params.to_h
        end
        positional.merge(keyword_params).stringify_keys
      end

      def array_value(value)
        case value
        when Array
          value
        when nil
          []
        else
          [value]
        end
      end
    end
  end
end
