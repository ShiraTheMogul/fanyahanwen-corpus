# frozen_string_literal: true

require "set"
require "time"
module CorpusSearch
  # Per-query, per-file hit cache.
  #
  # A changed file invalidates only that file's hits for a query. Other files are
  # reused, which is the important behaviour for a growing corpus.
  class QueryCache
    def initialize(query:, cache_store: CacheStore.new)
      @query = query
      @cache_store = cache_store
      @path = File.join("query_caches", "#{@query.cache_key}.json.gz")
      @payload = @cache_store.read_json(@path) || fresh_payload
    end

    def current_hits_for(doc)
      entry = @payload.dig("files", doc["id"])
      return nil unless entry
      return nil unless entry["fingerprint"] == doc["fingerprint"]

      Array(entry["hits"])
    end

    def write_hits_for(doc, hits)
      @payload["files"][doc["id"]] = {
        "path" => doc["path"],
        "fingerprint" => doc["fingerprint"],
        "scanned_at" => Time.now.utc.iso8601,
        "hits" => hits
      }
    end

    def prune_to!(doc_ids)
      allowed = doc_ids.to_set
      @payload["files"].keys.each do |doc_id|
        @payload["files"].delete(doc_id) unless allowed.include?(doc_id)
      end
    end

    def save!
      @payload["updated_at"] = Time.now.utc.iso8601
      @cache_store.write_json(@path, @payload)
    end

    private

    def fresh_payload
      {
        "version" => 3,
        "query" => @query.to_h,
        "created_at" => Time.now.utc.iso8601,
        "updated_at" => nil,
        "files" => {}
      }
    end
  end
end
