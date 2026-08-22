# frozen_string_literal: true

require "digest"
require "json"
require "pathname"

# Read-only facade over the external CBDB SQLite and the two disposable lookup
# indexes. Every attached database is queried in place; the unified layer does
# not duplicate CBDB authority records.
class HistoricalAuthorityStore
  CBDB_CITATION = "Harvard University, Academia Sinica, and Peking University, China Biographical Database (May 2025), https://projects.iq.harvard.edu/cbdb"
  CBDB_URL = "https://projects.iq.harvard.edu/cbdb"
  CBDB_LICENSE = "CC BY-NC-SA 4.0"

  attr_reader :cbdb_path, :lookup_path, :historical_path, :cbdb_release

  def self.default(cache_store: CorpusSearch::CacheStore.new, logger: Rails.logger)
    local = CbdbUpdater.current_local(cache_store: cache_store)
    new(
      cbdb_path: local&.sqlite_path,
      cbdb_release: local&.release,
      lookup_path: CbdbLookupIndex.path(cache_store: cache_store),
      historical_path: HistoricalAuthorityIndex.path(cache_store: cache_store),
      cache_store: cache_store,
      logger: logger
    )
  end

  def initialize(cbdb_path:, lookup_path:, historical_path:, cbdb_release: nil, cache_store: CorpusSearch::CacheStore.new, logger: nil)
    @cbdb_path = path_or_nil(cbdb_path)
    @cbdb_release = cbdb_release.to_h
    @lookup_path = path_or_nil(lookup_path)
    @historical_path = path_or_nil(historical_path)
    @cache_store = cache_store
    @logger = logger
  end

  def cbdb_available?
    @cbdb_path&.file? == true
  end

  def lookup_available?
    return @lookup_available if defined?(@lookup_available)
    return @lookup_available = false unless @lookup_path&.file?
    return @lookup_available = false unless cbdb_available?

    metadata = CbdbLookupIndex.metadata(cache_store: @cache_store, index_path: @lookup_path)
    source_sha = metadata["source_sha256"].to_s
    local_sha = @cbdb_release["sha256"].to_s
    if !source_sha.empty? && !local_sha.empty? && source_sha == local_sha
      return @lookup_available = true
    end

    # Only hash the large source when no cached release fingerprint is available.
    @lookup_available = !source_sha.empty? && source_sha == Digest::SHA256.file(@cbdb_path).hexdigest
  rescue StandardError => e
    @logger&.warn("[authority] CBDB lookup provenance check failed: #{e.class}: #{e.message}")
    @lookup_available = false
  end

  def historical_available?
    return @historical_available if defined?(@historical_available)

    @historical_available = @historical_path&.file? == true && HistoricalAuthorityIndex.current?(
      cache_store: @cache_store,
      index_path: @historical_path
    )
  rescue StandardError => e
    @logger&.warn("[authority] historical index provenance check failed: #{e.class}: #{e.message}")
    @historical_available = false
  end

  def available?
    cbdb_available? || historical_available?
  end

  def with_database
    require "sqlite3"

    db = SQLite3::Database.new(":memory:")
    db.results_as_hash = true
    attach!(db, "cbdb", @cbdb_path) if cbdb_available?
    attach!(db, "cbdb_lookup", @lookup_path) if lookup_available?
    attach!(db, "historical", @historical_path) if historical_available?
    db.execute("PRAGMA query_only = ON")
    yield db
  ensure
    db&.close
  end

  def metadata
    cbdb_release = @cbdb_release
    historical = HistoricalAuthorityIndex.metadata(cache_store: @cache_store, index_path: @historical_path)
    lookup = CbdbLookupIndex.metadata(cache_store: @cache_store, index_path: @lookup_path)
    {
      "cbdb_available" => cbdb_available?,
      "cbdb_filename" => @cbdb_path&.basename&.to_s,
      "cbdb_sha256" => cbdb_release["sha256"].to_s,
      "cbdb_citation" => CBDB_CITATION,
      "cbdb_url" => CBDB_URL,
      "cbdb_license" => CBDB_LICENSE,
      "cbdb_lookup_names" => lookup["names"].to_i,
      "historical_available" => historical_available?,
      "historical_fingerprint" => historical["fingerprint"].to_s,
      "supplementary_sha256" => historical["supplementary_sha256"].to_s,
      "curated_era_filename" => historical["curated_era_filename"].to_s,
      "curated_era_sha256" => historical["curated_era_sha256"].to_s,
      "curated_eras" => historical["curated_eras"].to_i,
      "historical_people" => historical["people"].to_i,
      "historical_names" => historical["names"].to_i,
      "historical_eras" => historical["eras"].to_i,
      "historical_era_names" => historical["era_names"].to_i,
      "historical_era_epochs" => historical["era_epochs"].to_i,
      "historical_era_local_use_intervals" => historical["era_local_use_intervals"].to_i,
      "historical_era_foreign_adoptions" => historical["era_foreign_adoptions"].to_i,
      "traditional_ruler_chronologies" => historical["traditional_ruler_chronologies"].to_i,
      "rulers_japan" => historical["rulers_japan"].to_i,
      "rulers_korea" => historical["rulers_korea"].to_i,
      "rulers_vietnam" => historical["rulers_vietnam"].to_i,
      "eras_japan" => historical["eras_japan"].to_i,
      "eras_korea" => historical["eras_korea"].to_i,
      "eras_vietnam" => historical["eras_vietnam"].to_i,
      "east_asia_snapshot_version" => historical["east_asia_snapshot_version"].to_i,
      "east_asia_generated_at_utc" => historical["east_asia_generated_at_utc"].to_s,
      "east_asia_snapshot_sha256" => historical["east_asia_snapshot_sha256"].to_s,
      "east_asia_wikidata_license" => historical["east_asia_wikidata_license"].to_s,
      "east_asia_wikipedia_license" => historical["east_asia_wikipedia_license"].to_s,
      "east_asia_sources" => parse_json_object(historical["east_asia_sources_json"]),
      "equivalence_version" => historical["equivalence_version"].to_s
    }.compact
  end

  private

  def parse_json_object(value)
    parsed = JSON.parse(value.to_s)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  def path_or_nil(value)
    text = value.to_s
    text.empty? ? nil : Pathname(text).expand_path
  end

  def attach!(db, schema, path)
    escaped = path.to_s.gsub("'", "''")
    db.execute("ATTACH DATABASE '#{escaped}' AS #{schema}")
  end
end
