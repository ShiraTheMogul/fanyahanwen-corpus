# frozen_string_literal: true

# Compatibility facade for callers/tests written while date resolution was
# CBDB-only. The implementation is now pan-East-Asian.
class CbdbHistoricalDateResolver
  def self.resolve(metadata: nil, store: HistoricalAuthorityStore.default, **context)
    new(store: store).resolve(metadata, **context)
  end

  def initialize(store: nil, source_path: nil, lookup_path: nil, cache_store: CorpusSearch::CacheStore.new, **_unused)
    @store = store || HistoricalAuthorityStore.new(
      cbdb_path: source_path,
      cbdb_release: {},
      lookup_path: lookup_path,
      historical_path: HistoricalAuthorityIndex.path(cache_store: cache_store),
      cache_store: cache_store,
      logger: nil
    )
    @resolver = HistoricalDateResolver.new(store: @store)
  end

  def resolve(value = nil, **context)
    metadata = if value.respond_to?(:to_h) && !value.is_a?(String)
      value.to_h.stringify_keys.merge(context.stringify_keys)
    else
      context.stringify_keys.merge("date_label" => value.to_s)
    end
    @resolver.resolve(metadata: metadata)
  end
end
