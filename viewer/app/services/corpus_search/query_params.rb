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

        folder_scope = parse_folder_scope(source)

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
          include_folders: folder_scope.fetch(:include),
          exclude_folders: folder_scope.fetch(:exclude)
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

      def parse_folder_scope(source)
        rules = source["folder_rules"]
        return {
          include: array_value(source["folders"]),
          exclude: array_value(source["exclude_folders"])
        } if rules.blank?

        entries = if rules.respond_to?(:to_unsafe_h)
                    rules.to_unsafe_h.values
                  elsif rules.is_a?(Hash)
                    rules.values
                  else
                    Array(rules)
                  end

        entries.each_with_object({ include: [], exclude: [] }) do |entry, scope|
          values = entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry.to_h
          values = values.stringify_keys
          path = values["path"].to_s.strip
          next if path.empty?

          destination = truthy?(values["exclude"]) ? :exclude : :include
          scope[destination] << path
        end
      end

      def truthy?(value)
        %w[1 true yes on].include?(value.to_s.downcase)
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
