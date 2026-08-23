# frozen_string_literal: true

require "digest"
require "json"
require "pathname"

# Disposable cache for automatic historical annotations.
#
# The cache key includes the text, corpus metadata, and authority metadata, so
# edits to a work or an authority rebuild naturally produce a different entry.
# Local user suppressions remain browser-side and are deliberately not cached.
class HistoricalAutoAnnotationCache
  # This version describes annotation *semantics*, not merely the JSON shape.
  # Bump it whenever matching behaviour changes in a way which could make an
  # existing positive or empty result stale. A stale empty cache entry can hide
  # an annotator fix completely, because the annotator is never called again.
  VERSION = 9
  CACHE_DIRECTORY = "authority_annotations/v9"

  Result = Data.define(:items, :context, :authority, :cached)

  def self.fetch(text:, metadata:, cache_identity: nil, store: HistoricalAuthorityStore.default, cache_store: CorpusSearch::CacheStore.new)
    new(store: store, cache_store: cache_store).fetch(
      text: text,
      metadata: metadata,
      cache_identity: cache_identity
    )
  end

  def initialize(store:, cache_store:)
    @store = store
    @cache_store = cache_store
  end

  def fetch(text:, metadata:, cache_identity: nil)
    fingerprint = cache_key(text: text, metadata: metadata)
    identity = cache_identity.to_s.strip
    identity = fingerprint if identity.empty?
    path = "#{CACHE_DIRECTORY}/#{Digest::SHA256.hexdigest(identity)}.json.gz"
    cached = @cache_store.read_json(path, freeze: true)

    if cached_payload?(cached, fingerprint: fingerprint)
      return Result.new(
        items: Array(cached["items"]),
        context: cached["context"].is_a?(Hash) ? cached["context"] : {},
        authority: cached["authority"].is_a?(Hash) ? cached["authority"] : {},
        cached: true
      )
    end

    result = CbdbAutoAnnotator.call(text: text, metadata: metadata, store: @store)
    authority = authority_metadata(result.authority)
    payload = {
      "version" => VERSION,
      "fingerprint" => fingerprint,
      "items" => result.items,
      "context" => result.context,
      "authority" => authority
    }

    # A partial authority query is useful for the current request, but it is not
    # a stable fact about the text. Likewise an unavailable authority layer must
    # not become a durable "0 matches" result. Both states are retried next time.
    @cache_store.write_json(path, payload) if cacheable?(authority)

    Result.new(
      items: result.items,
      context: result.context,
      authority: authority,
      cached: false
    )
  end

  private

  def authority_metadata(base = nil)
    metadata = base.respond_to?(:to_h) ? base.to_h : {}
    metadata = metadata.stringify_keys if metadata.respond_to?(:stringify_keys)
    metadata.merge(
      "cbdb_lookup_available" => (@store.respond_to?(:lookup_available?) && @store.lookup_available?),
      "historical_available" => (@store.respond_to?(:historical_available?) && @store.historical_available?)
    )
  rescue StandardError
    metadata || {}
  end

  def cacheable?(authority)
    data = authority.to_h.stringify_keys
    usable_source = data["cbdb_lookup_available"] == true || data["historical_available"] == true
    usable_source && data["annotation_partial"] != true
  rescue StandardError
    false
  end

  def cache_key(text:, metadata:)
    digest = Digest::SHA256.new
    digest << "historical-auto-annotation-v#{VERSION}\0"
    digest << Digest::SHA256.hexdigest(text.to_s)
    digest << "\0"
    digest << canonical_json(metadata.to_h)
    digest << "\0"
    base_authority = begin
      @store.respond_to?(:metadata) ? @store.metadata.to_h : {}
    rescue StandardError
      {}
    end
    digest << canonical_json(authority_metadata(base_authority))
    digest.hexdigest
  end

  def cached_payload?(payload, fingerprint:)
    payload.is_a?(Hash) &&
      payload["version"].to_i == VERSION &&
      payload["fingerprint"].to_s == fingerprint.to_s &&
      payload["items"].is_a?(Array)
  end

  def canonical_json(value)
    JSON.generate(canonical_value(value))
  rescue JSON::GeneratorError, TypeError
    value.to_s
  end

  def canonical_value(value)
    case value
    when Hash
      value.to_h.keys.map(&:to_s).sort.to_h do |key|
        original = value.key?(key) ? value[key] : value[key.to_sym]
        [key, canonical_value(original)]
      end
    when Array
      value.map { |entry| canonical_value(entry) }
    when Pathname
      value.to_s
    else
      value
    end
  end
end
