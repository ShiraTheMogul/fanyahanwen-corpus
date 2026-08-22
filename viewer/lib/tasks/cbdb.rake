# frozen_string_literal: true

namespace :cbdb do
  desc "Check for the latest CBDB SQLite release and rebuild its name-pointer cache"
  task refresh_and_build: :environment do
    update = CbdbUpdater.refresh_if_needed!
    puts "[cbdb] #{update.message}"

    if update.available?
      lookup = CbdbLookupIndex.build_if_needed!(
        source_path: update.sqlite_path,
        source_release: update.release
      )
      puts "[cbdb] #{lookup.message}"
    else
      warn "[cbdb] No usable CBDB database is available."
    end
  end

  desc "Show installed CBDB status without downloading anything"
  task status: :environment do
    local = CbdbUpdater.current_local
    if local&.available?
      puts "[cbdb] #{local.message}"
      puts "[cbdb] SQLite: #{local.sqlite_path}"
      puts "[cbdb] SHA-256: #{local.release['sha256']}" if local.release['sha256'].present?
      lookup = CbdbLookupIndex.metadata
      if lookup.present?
        puts "[cbdb] Lookup source SHA-256: #{lookup['source_sha256']}"
        puts "[cbdb] Lookup name pointers: #{lookup['names']}"
      else
        puts "[cbdb] Lookup cache has not been built."
      end
    else
      puts "[cbdb] No local CBDB SQLite database found under #{Rails.root.join('data')}."
    end
  end

  desc "Verify the installed CBDB SQLite with SHA-256 and SQLite quick_check"
  task verify: :environment do
    result = CbdbUpdater.verify_local!
    abort "[cbdb] #{result.message}" unless result.available?
    puts "[cbdb] #{result.message}"
  end
end

namespace :authority do
  desc "Ensure local authority indexes are usable for corpus maintenance without refreshing healthy network snapshots"
  task ensure_ready: :environment do
    allow_incomplete = ENV["ALLOW_INCOMPLETE_HISTORICAL_AUTHORITY"].to_s == "1"

    local_cbdb = CbdbUpdater.current_local
    unless local_cbdb&.available?
      update = CbdbUpdater.refresh_if_needed!
      puts "[cbdb] #{update.message}"
      local_cbdb = CbdbUpdater.current_local
    end
    unless local_cbdb&.available?
      message = "CBDB is unavailable; Chinese era/date authority would be incomplete."
      allow_incomplete ? warn("[authority] WARNING: #{message}") : abort("[authority] #{message} Set ALLOW_INCOMPLETE_HISTORICAL_AUTHORITY=1 only for an intentional partial build.")
    end

    if local_cbdb&.available?
      lookup = CbdbLookupIndex.build_if_needed!(
        source_path: local_cbdb.sqlite_path,
        source_release: local_cbdb.release
      )
      puts "[cbdb] #{lookup.message}"
    end

    snapshot = EastAsianAuthorityUpdater.current
    if snapshot.is_a?(Hash) && snapshot["version"].to_i == EastAsianAuthorityUpdater::VERSION
      puts "[authority] Using the installed East Asian ruler/era snapshot (network refresh skipped for manifest determinism)."
    else
      east_asia = EastAsianAuthorityUpdater.refresh_if_needed!
      puts "[authority] #{east_asia.message}"
      snapshot = east_asia.payload
    end

    unless snapshot.is_a?(Hash)
      message = "Japanese/Korean/Vietnamese ruler-era authority is unavailable."
      allow_incomplete ? warn("[authority] WARNING: #{message}") : abort("[authority] #{message} Set ALLOW_INCOMPLETE_HISTORICAL_AUTHORITY=1 only for an intentional partial build.")
    end

    historical = HistoricalAuthorityIndex.build_if_needed!(snapshot: snapshot)
    puts "[authority] #{historical.message}"
    unless historical.available? && HistoricalAuthorityIndex.current?(snapshot: snapshot)
      message = "Historical authority index is missing or stale after rebuild."
      allow_incomplete ? warn("[authority] WARNING: #{message}") : abort("[authority] #{message}")
    end
  end

  desc "Refresh CBDB plus Japanese/Korean/Vietnamese ruler-era data and rebuild authority indexes"
  task refresh_and_build: :environment do
    allow_incomplete = ENV["ALLOW_INCOMPLETE_HISTORICAL_AUTHORITY"].to_s == "1"

    Rake::Task["cbdb:refresh_and_build"].invoke
    local_cbdb = CbdbUpdater.current_local
    unless local_cbdb&.available?
      message = "CBDB is unavailable; Chinese era/date authority would be incomplete."
      allow_incomplete ? warn("[authority] WARNING: #{message}") : abort("[authority] #{message} Set ALLOW_INCOMPLETE_HISTORICAL_AUTHORITY=1 only for an intentional partial build.")
    end
    if local_cbdb&.available? && !HistoricalAuthorityStore.default.lookup_available?
      message = "CBDB name-pointer cache is missing or stale; automatic CBDB person/place/office annotation would be incomplete."
      allow_incomplete ? warn("[authority] WARNING: #{message}") : abort("[authority] #{message}")
    end

    east_asia = EastAsianAuthorityUpdater.refresh_if_needed!(force: ENV["FORCE"].to_s == "1")
    puts "[authority] #{east_asia.message}"
    unless east_asia.available?
      message = "Japanese/Korean/Vietnamese ruler-era authority is unavailable."
      allow_incomplete ? warn("[authority] WARNING: #{message}") : abort("[authority] #{message} Set ALLOW_INCOMPLETE_HISTORICAL_AUTHORITY=1 only for an intentional partial build.")
    end

    historical = HistoricalAuthorityIndex.build_if_needed!(snapshot: east_asia.payload)
    puts "[authority] #{historical.message}"
    unless historical.available? && HistoricalAuthorityIndex.current?(snapshot: east_asia.payload)
      message = "Historical authority index is missing or stale after rebuild."
      allow_incomplete ? warn("[authority] WARNING: #{message}") : abort("[authority] #{message}")
    end
  end

  desc "Refresh only Japanese/Korean/Vietnamese ruler-era source data (FORCE=1 bypasses the TTL)"
  task refresh_east_asia: :environment do
    east_asia = EastAsianAuthorityUpdater.refresh_if_needed!(force: ENV["FORCE"].to_s == "1")
    puts "[authority] #{east_asia.message}"
    abort "[authority] East Asian ruler/era authority is unavailable." unless east_asia.available?

    historical = HistoricalAuthorityIndex.build_if_needed!(snapshot: east_asia.payload)
    puts "[authority] #{historical.message}"
    abort "[authority] Historical authority index is missing or stale after rebuild." unless historical.available? && HistoricalAuthorityIndex.current?(snapshot: east_asia.payload)
  end

  desc "Show local historical authority status without contacting the network"
  task status: :environment do
    Rake::Task["cbdb:status"].invoke

    snapshot = EastAsianAuthorityUpdater.current
    if snapshot.present?
      grouped_rulers = Array(snapshot["rulers"]).group_by { |row| row["country"].to_s }
      grouped_eras = Array(snapshot["eras"]).group_by { |row| row["country"].to_s }
      puts "[authority] East Asian snapshot v#{snapshot['version']}: #{snapshot['rulers'].to_a.length} rulers; #{snapshot['eras'].to_a.length} era/local-use records"
      %w[Japan Korea Vietnam].each do |country|
        puts "[authority]   #{country}: #{Array(grouped_rulers[country]).length} rulers; #{Array(grouped_eras[country]).length} era/local-use records"
      end
      puts "[authority] Snapshot generated: #{snapshot['generated_at_utc']}"
      puts "[authority] Wikidata: #{snapshot['wikidata_license']} | Wikipedia discovery/enrichment: #{snapshot['wikipedia_discovery_license']}"
      discovery_stats = snapshot["discovery_stats"].to_h
      %w[Japan Korea Vietnam].each do |country|
        stats = discovery_stats[country].to_h
        next if stats.empty?
        puts "[authority]   #{country} discovery audit: discarded #{stats['discarded_nonlist_rulers'].to_i} linked non-list ruler candidate(s) and #{stats['discarded_nonlist_eras'].to_i} linked non-list era candidate(s)"
      end
      degraded = Array(snapshot["degraded_sources"])
      if degraded.any?
        puts "[authority] Snapshot used #{degraded.length} degraded-source fallback(s):"
        degraded.each { |message| puts "[authority]   - #{message}" }
      end
    else
      puts "[authority] East Asian ruler/era snapshot has not been built."
    end

    metadata = HistoricalAuthorityIndex.metadata
    if metadata.present?
      puts "[authority] Historical people: #{metadata['people']}"
      puts "[authority] Searchable names: #{metadata['names']} (#{metadata['explicit_names']} explicit; #{metadata['derived_names']} derived)"
      puts "[authority] Era records: #{metadata['eras']}"
      puts "[authority] Project-curated era records: #{metadata['curated_eras']}"
      puts "[authority] Era name forms: #{metadata['era_names']} (#{metadata['explicit_era_names']} explicit; #{metadata['derived_era_names']} derived)"
      puts "[authority] Epoch-backed calendars: #{metadata['era_epochs']}"
      puts "[authority] Foreign/local era adoptions: #{metadata['era_foreign_adoptions']}"
      puts "[authority] Rulers with explicitly traditional/disputed chronology: #{metadata['traditional_ruler_chronologies']}"
      puts "[authority] Character equivalence: #{metadata['equivalence_version']}"
      puts "[authority] Index status: #{HistoricalAuthorityIndex.current? ? 'current' : 'stale — run bin/rails authority:refresh_and_build'}"
    else
      puts "[authority] Historical authority index has not been built."
    end
  end

  desc "Verify CBDB plus the East Asian snapshot and disposable historical SQLite index"
  task verify: :environment do
    cbdb = CbdbUpdater.verify_local!
    abort "[authority] #{cbdb.message}" unless cbdb.available?
    puts "[authority] #{cbdb.message}"

    snapshot = EastAsianAuthorityUpdater.current
    abort "[authority] East Asian snapshot is missing." unless snapshot.is_a?(Hash)
    abort "[authority] East Asian snapshot version is stale (#{snapshot['version'].inspect}; expected #{EastAsianAuthorityUpdater::VERSION})." unless snapshot["version"].to_i == EastAsianAuthorityUpdater::VERSION

    index_path = HistoricalAuthorityIndex.path
    abort "[authority] Historical authority SQLite is missing: #{index_path}" unless index_path.file?
    abort "[authority] Historical authority index provenance is stale." unless HistoricalAuthorityIndex.current?(snapshot: snapshot)

    require "sqlite3"
    db = SQLite3::Database.new(index_path.to_s, readonly: true)
    check = db.get_first_value("PRAGMA quick_check").to_s
    abort "[authority] Historical authority SQLite quick_check failed: #{check}" unless check == "ok"
    puts "[authority] Historical authority SQLite quick_check: ok"
  ensure
    db&.close
  end
end

# Rake merges declarations for an existing task name. This prerequisite runs
# before the established force-refresh manifest body, so chronology authorities
# are current before metadata dates are derived into the search manifest.
task "corpus_search:rebuild_manifest" => "authority:ensure_ready"
