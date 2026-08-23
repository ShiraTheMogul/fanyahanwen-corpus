# frozen_string_literal: true

# Automatic authority annotation also uses the bounded orthography registry.
# The base initializer constructs CharacterEquivalenceRegistry(level: "broad"),
# which performs a VariantMapping version query during construction, so mirror
# its small initializer and avoid creating that database-backed graph.
module CbdbAutoAnnotatorStaticNames
  def initialize(text:, metadata:, store:)
    @text = text.to_s
    @chars = @text.each_char.to_a
    @metadata = metadata.to_h.stringify_keys
    @store = normalize_store(store)
    @equivalence = AuthorityHanVariantRegistry.instance
    @prefix_cache = {}
  end

  # The base implementation catches every StandardError and turns it into an
  # empty match set. That makes a broken SQLite authority lookup look exactly
  # like a healthy text with zero names. Let request-facing callers see the
  # failure so HistoricalAutoAnnotations can return a visible 422 error state.
  def call
    return Result.new(items: [], context: temporal_context, authority: @store.metadata) unless @store.available?

    @context = temporal_context
    matches = []
    @store.with_database do |db|
      @db = db
      prefixes = text_prefixes
      matches.concat(cbdb_matches(prefixes)) if @store.lookup_available? && prefixes.any?
      matches.concat(historical_matches(prefixes)) if @store.historical_available? && prefixes.any?
      matches.concat(single_character_diviner_matches) if @store.historical_available?
    ensure
      @db = nil
    end

    Result.new(
      items: resolve_overlaps(matches).map { |match| public_item(match) },
      context: @context,
      authority: @store.metadata
    )
  end
end
