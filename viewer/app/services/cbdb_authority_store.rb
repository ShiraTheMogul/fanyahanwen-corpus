# frozen_string_literal: true

require "pathname"

# Backwards-compatible facade retained for older CBDB-only callers. New code
# should use HistoricalAuthorityStore, which can attach CBDB and the East Asian
# authority cache together.
class CbdbAuthorityStore
  SOURCE_URL = HistoricalAuthorityStore::CBDB_URL
  SOURCE_LICENSE = HistoricalAuthorityStore::CBDB_LICENSE

  attr_reader :source_path, :lookup_path, :release, :cache_store

  def self.default(cache_store: CorpusSearch::CacheStore.new, logger: Rails.logger)
    local = CbdbUpdater.current_local(cache_store: cache_store)
    new(local: local, lookup_path: CbdbLookupIndex.path(cache_store: cache_store), cache_store: cache_store, logger: logger)
  end

  def initialize(local:, lookup_path:, cache_store:, supplementary_path: nil, logger: nil)
    @source_path = Pathname(local&.sqlite_path.to_s)
    @lookup_path = Pathname(lookup_path.to_s)
    @supplementary_path = supplementary_path && Pathname(supplementary_path.to_s)
    @release = local&.release.to_h
    @cache_store = cache_store
    @logger = logger
  end

  def source_available? = @source_path.file?
  def lookup_available? = @lookup_path.file?
  def supplementary_available? = @supplementary_path&.file? == true
  def available? = source_available? && lookup_available?

  def with_database(attach_lookup: true, attach_supplementary: true)
    raise "CBDB authority data is unavailable" unless source_available?

    require "sqlite3"
    db = SQLite3::Database.new(@source_path.to_s, readonly: true)
    db.results_as_hash = true
    attach(db, "fanya_lookup", @lookup_path) if attach_lookup && lookup_available?
    attach(db, "fanya_supplementary", @supplementary_path) if attach_supplementary && supplementary_available?
    db.execute("PRAGMA query_only = ON")
    yield db
  ensure
    db&.close
  end

  def metadata
    lookup = CbdbLookupIndex.metadata(cache_store: @cache_store, index_path: @lookup_path)
    {
      "source_filename" => @source_path.basename.to_s,
      "source_sha256" => @release["sha256"].to_s.presence || lookup["source_sha256"].to_s,
      "lookup_built_at_utc" => lookup["built_at_utc"].to_s,
      "source_citation" => HistoricalAuthorityStore::CBDB_CITATION,
      "source_url" => SOURCE_URL,
      "source_license" => SOURCE_LICENSE
    }.reject { |_key, value| value.blank? }
  end

  private

  def attach(db, schema, path)
    escaped = path.to_s.gsub("'", "''")
    db.execute("ATTACH DATABASE '#{escaped}' AS #{schema}")
  end
end
