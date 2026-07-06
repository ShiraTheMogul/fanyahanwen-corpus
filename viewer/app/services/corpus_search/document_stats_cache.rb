# frozen_string_literal: true

require "fileutils"
require "set"
require "sqlite3"

module CorpusSearch
  # Query-independent body statistics keyed by each document fingerprint.
  #
  # Searchable-character counts and body fingerprints do not depend on the
  # searched word. A compact character Bloom filter is also retained so a later
  # bounded interactive query can inspect likely cached documents first without
  # rereading every corpus file.
  class DocumentStatsCache
    VERSION = 2
    BUSY_TIMEOUT_MS = 10_000
    Stats = Data.define(:searchable_characters, :body_fingerprint, :character_bloom)

    def initialize(cache_store: CacheStore.new)
      @cache_store = cache_store
      @path = @cache_store.absolute("document_stats.sqlite3")
      FileUtils.mkdir_p(@path.dirname)
      open_database!
      prepare_schema!
      @transaction_open = false
      @closed = false
    end

    def fetch(doc, punctuation:)
      count_column = punctuation.to_s == "respect" ? "respect_count" : "ignore_count"
      row = @database.get_first_row(
        <<~SQL,
          SELECT fingerprint, body_fingerprint, #{count_column}, character_bloom
          FROM document_stats
          WHERE doc_id = ?
        SQL
        [doc.fetch("id").to_s]
      )
      return nil unless row
      return nil unless row[0].to_s == doc["fingerprint"].to_s
      return nil if row[2].nil?

      Stats.new(
        searchable_characters: row[2].to_i,
        body_fingerprint: row[1].to_s,
        character_bloom: row[3]
      )
    end

    def write(doc, punctuation:, searchable_characters:, body_fingerprint:, character_bloom: nil)
      begin_transaction!
      ignore_count = punctuation.to_s == "respect" ? nil : searchable_characters.to_i
      respect_count = punctuation.to_s == "respect" ? searchable_characters.to_i : nil
      bloom = character_bloom&.to_s&.b

      @database.execute(
        <<~SQL,
          INSERT INTO document_stats(
            doc_id, fingerprint, body_fingerprint, ignore_count, respect_count, character_bloom
          ) VALUES(?, ?, ?, ?, ?, ?)
          ON CONFLICT(doc_id) DO UPDATE SET
            fingerprint = excluded.fingerprint,
            body_fingerprint = excluded.body_fingerprint,
            ignore_count = CASE
              WHEN excluded.ignore_count IS NOT NULL THEN excluded.ignore_count
              WHEN document_stats.fingerprint = excluded.fingerprint THEN document_stats.ignore_count
              ELSE NULL
            END,
            respect_count = CASE
              WHEN excluded.respect_count IS NOT NULL THEN excluded.respect_count
              WHEN document_stats.fingerprint = excluded.fingerprint THEN document_stats.respect_count
              ELSE NULL
            END,
            character_bloom = CASE
              WHEN excluded.character_bloom IS NOT NULL THEN excluded.character_bloom
              WHEN document_stats.fingerprint = excluded.fingerprint THEN document_stats.character_bloom
              ELSE NULL
            END
        SQL
        [
          doc.fetch("id").to_s,
          doc["fingerprint"].to_s,
          body_fingerprint.to_s,
          ignore_count,
          respect_count,
          bloom
        ]
      )
      self
    end

    # Return only IDs that are promising according to already-cached body
    # signatures. Rows without a signature are unknown and are deliberately not
    # returned. Callers use these IDs for ordering only, never for exclusion.
    def matching_document_ids(term_patterns:, alternatives: false)
      matching = Set.new
      @database.execute(
        "SELECT doc_id, character_bloom FROM document_stats WHERE character_bloom IS NOT NULL"
      ) do |row|
        next unless CharacterBloom.maybe_matches?(
          row[1],
          term_patterns: term_patterns,
          alternatives: alternatives
        )

        matching << row[0].to_s
      end
      matching
    end

    def save!
      return self unless @transaction_open

      @database.execute("COMMIT")
      @transaction_open = false
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

        CREATE TABLE IF NOT EXISTS document_stats (
          doc_id TEXT PRIMARY KEY,
          fingerprint TEXT NOT NULL,
          body_fingerprint TEXT NOT NULL,
          ignore_count INTEGER,
          respect_count INTEGER,
          character_bloom BLOB
        );
      SQL

      ensure_character_bloom_column!

      stored_version = @database.get_first_value(
        "SELECT value FROM cache_metadata WHERE key = 'version'"
      ).to_i
      return if stored_version == VERSION

      # Version 2 adds an optional prioritisation hint. Existing counts remain
      # valid, so migrate in place rather than deleting a costly warm cache.
      @database.execute("DELETE FROM cache_metadata WHERE key = 'version'")
      @database.execute(
        "INSERT INTO cache_metadata(key, value) VALUES('version', ?)",
        [VERSION.to_s]
      )
    end

    def ensure_character_bloom_column!
      columns = @database.execute("PRAGMA table_info(document_stats)").map { |row| row[1].to_s }
      return if columns.include?("character_bloom")

      @database.execute("ALTER TABLE document_stats ADD COLUMN character_bloom BLOB")
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
    end
  end
end
