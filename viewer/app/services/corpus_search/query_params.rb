# frozen_string_literal: true

module CorpusSearch
  # The boundary between GET parameters and the search domain objects. The
  # controller should not know how individual query fields are normalised.
  class QueryParams
    METADATA_KEYS = %w[nation period region author year_start year_end].freeze

    class << self
      def parse(params, locale: I18n.locale)
        source = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
        source = source.stringify_keys

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
          exclude_folders: array_value(source["exclude_folders"])
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

      def search_requested?(params)
        source = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
        source = source.stringify_keys
        source["q"].present? || array_value(source["terms"]).any? || source["search"].present?
      end

      private

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
