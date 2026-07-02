# frozen_string_literal: true

module CorpusSearch
  # A normalized query term whose units each carry a set of accepted source
  # forms. It keeps the entered form separate so non-literal matches can be
  # explained after the source offsets are known.
  class CharacterPattern
    attr_reader :query_units, :allowed_units

    def self.build(text, punctuation:, registry:, profile: NormalizationProfile.current)
      normalized = NormalizedText.build(text, punctuation: punctuation, profile: profile)
      new(query_units: normalized.units, registry: registry)
    end

    def initialize(query_units:, registry:)
      @query_units = Array(query_units).map(&:to_s).freeze
      @registry = registry
      @allowed_units = @query_units.map { |unit| @registry.forms_for(unit) }.freeze
      freeze
    end

    def empty?
      @query_units.empty?
    end

    def length
      @query_units.length
    end

    def positions_in(searchable_units)
      SearchText.positions_of_pattern(searchable_units, @allowed_units)
    end

    def signature
      @allowed_units.map { |forms| forms.to_a.sort.join("\u0001") }.join("\u0000")
    end

    def equivalence_matches_at(searchable:, search_start:, term_index: nil)
      @query_units.each_with_index.filter_map do |query_character, unit_index|
        source_search_offset = search_start.to_i + unit_index
        source_character = searchable.units[source_search_offset]
        next if source_character.nil? || source_character == query_character

        explanation = @registry.explanation(
          query_character: query_character,
          source_character: source_character
        )
        next unless explanation

        explanation.merge(
          "term_index" => term_index,
          "query_unit_offset" => unit_index,
          "source_search_offset" => source_search_offset,
          "source_offset" => searchable.original_offsets.fetch(source_search_offset)
        )
      end
    end
  end
end
