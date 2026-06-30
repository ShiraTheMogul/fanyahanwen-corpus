# frozen_string_literal: true

require "time"

module CorpusSearch
  # Small aggregate cache used by pages that only need corpus-wide counts.
  # Reading one snapshot is much cheaper than opening one compressed term index
  # for every character during a web request.
  class FrequencySnapshot
    CACHE_PATH = "single_character_frequencies.json.gz"
    VERSION = 1

    def self.build!(terms:, manifest:, cache_store: CacheStore.new)
      manifest_key = TermIndex.manifest_fingerprint(manifest)
      counts = {}
      stale_terms = []

      terms.map(&:to_s).uniq.each do |term|
        payload = cache_store.read_json(TermIndex.cache_path_for(term))
        unless TermIndex.current_for_manifest?(payload, manifest_key)
          stale_terms << term
          next
        end

        counts[term] = payload.fetch("entries", {}).values.sum do |row|
          row.is_a?(Hash) ? row["count"].to_i : 0
        end
      end

      payload = {
        "version" => VERSION,
        "generated_at" => Time.now.utc.iso8601,
        "manifest_fingerprint" => manifest_key,
        "counts" => counts,
        "stale_terms" => stale_terms
      }
      cache_store.write_json(CACHE_PATH, payload)
      payload
    end

    def self.counts(cache_store: CacheStore.new)
      payload = cache_store.read_json(CACHE_PATH)
      return {} unless payload.is_a?(Hash) && payload["version"].to_i == VERSION

      payload.fetch("counts", {}).transform_values(&:to_i)
    rescue Errno::EACCES, Errno::EIO
      {}
    end
  end
end
