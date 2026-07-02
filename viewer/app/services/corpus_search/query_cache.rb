# frozen_string_literal: true

require "set"
require "time"

module CorpusSearch
  # Per-query, per-file hit and denominator cache.
  #
  # A changed file invalidates only that file's cached search data. Searchable
  # character counts are stored beside hits so prepared statistical datasets do
  # not need to reread files already scanned for the same query.
  class QueryCache
    VERSION = 4

    def initialize(query:, cache_store: CacheStore.new)
      @query = query
      @cache_store = cache_store
      @path = File.join("query_caches", "#{@query.cache_key}.json.gz")
      cached = @cache_store.read_json(@path)
      @payload = cached.is_a?(Hash) && cached["version"].to_i == VERSION ? cached : fresh_payload
      @dirty = false
    end

    def current_hits_for(doc)
      entry = current_entry_for(doc)
      entry ? Array(entry["hits"]) : nil
    end

    def current_searchable_characters_for(doc)
      entry = current_entry_for(doc)
      return nil unless entry&.key?("searchable_characters")

      Integer(entry["searchable_characters"])
    rescue ArgumentError, TypeError
      nil
    end

    def write_hits_for(doc, hits, searchable_characters: nil)
      previous = @payload.dig("files", doc["id"]) || {}
      @payload["files"][doc["id"]] = {
        "path" => doc["path"],
        "fingerprint" => doc["fingerprint"],
        "scanned_at" => Time.now.utc.iso8601,
        "searchable_characters" => searchable_characters.nil? ? previous["searchable_characters"] : searchable_characters.to_i,
        "hits" => hits
      }.compact
      @dirty = true
    end

    def write_searchable_characters_for(doc, value)
      entry = current_entry_for(doc)
      return unless entry

      normalized = value.to_i
      return if entry["searchable_characters"] == normalized

      entry["searchable_characters"] = normalized
      @dirty = true
    end

    def prune_to!(doc_ids)
      allowed = doc_ids.to_set
      @payload["files"].keys.each do |doc_id|
        next if allowed.include?(doc_id)

        @payload["files"].delete(doc_id)
        @dirty = true
      end
    end

    def save!
      return unless @dirty

      @payload["version"] = VERSION
      @payload["updated_at"] = Time.now.utc.iso8601
      @cache_store.write_json(@path, @payload)
      @dirty = false
    end

    private

    def current_entry_for(doc)
      entry = @payload.dig("files", doc["id"])
      return nil unless entry
      return nil unless entry["fingerprint"] == doc["fingerprint"]

      entry
    end

    def fresh_payload
      {
        "version" => VERSION,
        "query" => @query.to_h,
        "created_at" => Time.now.utc.iso8601,
        "updated_at" => nil,
        "files" => {}
      }
    end
  end
end
