# frozen_string_literal: true

module Grammar
  class Entry
    KINDS = %w[function_word function pattern binome comparison concept].freeze
    IMPORTANCE = %w[core common less_common specialised].freeze

    attr_reader :attributes

    def initialize(attributes)
      @attributes = MarkdownDocument.stringify_keys(attributes.to_h)
    end

    def id
      attributes.fetch("id")
    end

    def kind
      attributes.fetch("kind")
    end

    def headword
      attributes["headword"].to_s
    end

    def title
      attributes["title"].presence || headword.presence || id
    end

    def path
      attributes.fetch("path")
    end

    def parent_id
      attributes["parent"].presence
    end

    def importance
      attributes["importance"].presence
    end

    def categories
      Array(attributes["categories"]).map(&:to_s)
    end

    def related_ids
      Array(attributes["related"]).map(&:to_s)
    end

    def comparison_ids
      Array(attributes["comparisons"]).map(&:to_s)
    end

    def characters
      explicit = Array(attributes["characters"]).map(&:to_s).reject(&:blank?)
      return explicit if explicit.any?

      headword.each_char.select { |character| character.match?(/\p{Han}/) }.uniq
    end

    def corpus_searches
      Array(attributes["corpus_searches"]).filter_map do |value|
        value.is_a?(Hash) ? MarkdownDocument.stringify_keys(value) : nil
      end
    end

    def needs_expansion?
      attributes["needs_expansion"] == true
    end

    def single_character?
      headword.each_char.count == 1 && headword.match?(/\A\p{Han}\z/)
    end

    # Only character-level function-word hubs should receive the large glyph
    # tile. Child function articles may share the same one-character headword,
    # but their descriptive titles need ordinary article typography.
    def character_hub?
      kind == "function_word" && single_character?
    end
  end
end
