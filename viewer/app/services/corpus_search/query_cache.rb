# frozen_string_literal: true

require "fileutils"
require "json"
require "sqlite3"

module CorpusSearch
  # Per-query, per-file hit and denominator cache.
  #
  # Earlier versions kept every scanned document inside one compressed JSON
  # object. A broad query therefore built a very large Ruby hash and rewrote the
  # whole gzip file at every checkpoint. The SQLite cache keeps the same logical
  # records, but reads and updates one document row at a time. This bounds Ruby
  # memory and makes checkpoints incremental.
  class QueryCache
    VERSION = 8
    BUSY_TIMEOUT_MS = 10_000
    Record = Data.define(:hits, :searchable_characters, :body_fingerprint)

    def initialize(query:, cache_store: CacheStore.new)
      @query = query
      @cache_store = cache_store
      @path = @cache_store.absolute(File.join("query_caches", "#{@query.cache_key}.sqlite3"))
      FileUtils.mkdir_p(@path.dirname)

      # Version 5 and earlier used one .json.gz file. Version 8 also
      # invalidates cached hit payloads created before stable JSON identities,
      # source URLs, and occurrence keys were carried on every hit.
      # It is not read by the new
      # cache and can be removed safely because all search caches are disposable.
      @cache_store.delete(File.join("query_caches", "#{@query.cache_key}.json.gz"))

      open_database!
      prepare_schema!
      @transaction_open = false
      @dirty = false
      @closed = false
      clear_last_entry
    end

    def current_hits_for(doc)
      current_record_for(doc)&.hits
    end

    def current_searchable_characters_for(doc)
      current_record_for(doc)&.searchable_characters
    end

    def current_body_fingerprint_for(doc)
      current_record_for(doc)&.body_fingerprint.presence
    end

    # A prepared analysis needs the three cached fields together. Returning one
    # record avoids three SQLite SELECTs and three JSON parses for every document.
    def current_record_for(doc)
      current_entry_for(doc)
    end

    def write_hits_for(doc, hits, searchable_characters: nil, body_fingerprint: nil)
      previous = if searchable_characters.nil? || body_fingerprint.blank?
        current_entry_for(doc)
      end
      write_entry(
        doc,
        hits: Array(hits),
        searchable_characters: searchable_characters.nil? ? previous&.searchable_characters : searchable_characters.to_i,
        body_fingerprint: body_fingerprint.presence || previous&.body_fingerprint
      )
    end

    def write_document_stats_for(doc, searchable_characters:, body_fingerprint:, hits: nil)
      previous = current_entry_for(doc)
      return if previous.nil? && hits.nil?

      normalized_hits = hits.nil? ? previous.hits : Array(hits)
      normalized_count = searchable_characters.to_i
      normalized_fingerprint = body_fingerprint.to_s.presence

      return if previous &&
        previous.searchable_characters == normalized_count &&
        previous.body_fingerprint == normalized_fingerprint &&
        previous.hits == normalized_hits

      write_entry(
        doc,
        hits: normalized_hits,
        searchable_characters: normalized_count,
        body_fingerprint: normalized_fingerprint
      )
    end

    # The query key already includes every scope and matching option. Rows that
    # refer to documents no longer present in the current manifest are harmless:
    # Runner never asks for them. Avoiding a 494,000-ID Set here saves substantial
    # memory on every broad search.
    def prune_to!(_doc_ids = nil)
      self
    end

    # Commit the current incremental batch. No full cache rewrite occurs.
    def save!
      return self if @closed || !@transaction_open

      @database.execute("COMMIT")
      @transaction_open = false
      @dirty = false
      self
    rescue SQLite3::Exception
      rollback_transaction!
      raise
    end

    def close
      return if @closed

      save!
      @database&.close
      @closed = true
    end

    private

    def open_database!
      @database = SQLite3::Database.new(@path.to_s)
      @database.busy_timeout(BUSY_TIMEOUT_MS)
      @database.results_as_hash = false
      @database.execute("PRAGMA synchronous = NORMAL")
      @database.execute("PRAGMA temp_store = MEMORY")
      @database.execute("PRAGMA journal_mode = #{@cache_store.sqlite_journal_mode}")
    rescue SQLite3::Exception
      @database&.close rescue nil
      FileUtils.rm_f(@path)
      FileUtils.rm_f("#{@path}-wal")
      FileUtils.rm_f("#{@path}-shm")
      @database = SQLite3::Database.new(@path.to_s)
      @database.busy_timeout(BUSY_TIMEOUT_MS)
      @database.results_as_hash = false
      @database.execute("PRAGMA synchronous = NORMAL")
    end

    def prepare_schema!
      @database.execute_batch(<<~SQL)
        CREATE TABLE IF NOT EXISTS cache_metadata (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS files (
          doc_id TEXT PRIMARY KEY,
          fingerprint TEXT NOT NULL,
          searchable_characters INTEGER,
          body_fingerprint TEXT,
          hits_json TEXT NOT NULL
        );
      SQL

      stored_version = @database.get_first_value(
        "SELECT value FROM cache_metadata WHERE key = 'version'"
      ).to_i

      return if stored_version == VERSION

      @database.execute("DELETE FROM files")
      @database.execute("DELETE FROM cache_metadata")
      @database.execute(
        "INSERT INTO cache_metadata(key, value) VALUES('version', ?)",
        [VERSION.to_s]
      )
      @database.execute(
        "INSERT INTO cache_metadata(key, value) VALUES('query', ?)",
        [JSON.generate(@query.to_h)]
      )
    end

    def current_entry_for(doc)
      doc_id = doc.fetch("id").to_s
      fingerprint = doc["fingerprint"].to_s
      if @last_entry_doc_id == doc_id && @last_entry_fingerprint == fingerprint
        return @last_entry
      end

      row = @database.get_first_row(
        <<~SQL,
          SELECT fingerprint, searchable_characters, body_fingerprint, hits_json
          FROM files
          WHERE doc_id = ?
        SQL
        [doc_id]
      )
      return remember_entry(doc_id, fingerprint, nil) unless row
      return remember_entry(doc_id, fingerprint, nil) unless row[0].to_s == fingerprint

      remember_entry(doc_id, fingerprint, Record.new(
        searchable_characters: row[1].nil? ? nil : row[1].to_i,
        body_fingerprint: row[2].to_s.presence,
        hits: JSON.parse(row[3].to_s)
      ))
    rescue JSON::ParserError
      remember_entry(doc_id, fingerprint, nil)
    end

    def write_entry(doc, hits:, searchable_characters:, body_fingerprint:)
      begin_transaction!
      @database.execute(
        <<~SQL,
          INSERT INTO files(doc_id, fingerprint, searchable_characters, body_fingerprint, hits_json)
          VALUES(?, ?, ?, ?, ?)
          ON CONFLICT(doc_id) DO UPDATE SET
            fingerprint = excluded.fingerprint,
            searchable_characters = excluded.searchable_characters,
            body_fingerprint = excluded.body_fingerprint,
            hits_json = excluded.hits_json
        SQL
        [
          doc.fetch("id").to_s,
          doc["fingerprint"].to_s,
          searchable_characters,
          body_fingerprint,
          JSON.generate(Array(hits))
        ]
      )
      @dirty = true
      remember_entry(
        doc.fetch("id").to_s,
        doc["fingerprint"].to_s,
        Record.new(
          hits: Array(hits),
          searchable_characters: searchable_characters,
          body_fingerprint: body_fingerprint
        )
      )
    end

    def begin_transaction!
      return if @transaction_open

      @database.execute("BEGIN")
      @transaction_open = true
    end

    def rollback_transaction!
      @database.execute("ROLLBACK") if @transaction_open
    rescue SQLite3::Exception
      nil
    ensure
      @transaction_open = false
      @dirty = false
    end

    def remember_entry(doc_id, fingerprint, entry)
      @last_entry_doc_id = doc_id
      @last_entry_fingerprint = fingerprint
      @last_entry = entry
    end

    def clear_last_entry
      @last_entry_doc_id = nil
      @last_entry_fingerprint = nil
      @last_entry = nil
    end
  end
end
