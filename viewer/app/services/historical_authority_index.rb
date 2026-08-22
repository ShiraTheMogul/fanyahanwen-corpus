# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "time"

# Rebuildable local index for project-maintained Shang/Xia people and the
# Japanese/Korean/Vietnamese ruler + era snapshot. CBDB remains attached and
# queried directly; this cache does not clone CBDB biographies.
class HistoricalAuthorityIndex
  VERSION = 7
  CACHE_PATH = "historical-authority-v7.sqlite3"
  SUPPLEMENTARY_SOURCE_PATH = Rails.root.join("data", "shang_people.xlsx")
  CURATED_ERA_SOURCE_PATH = Rails.root.join("data", "historical_eras.json")
  SUPPLEMENTARY_SHEETS = %w[Shang Xia].freeze
  REQUIRED_HEADERS = %w[
    person_id primary_name name_han aliases polity period year_start year_end
    date_label roles places source_citations external_ids notes
  ].freeze

  Result = Data.define(:status, :path, :fingerprint, :counts, :message) do
    def available? = path.present? && File.file?(path)
    def rebuilt? = status == :rebuilt
  end

  def self.path(cache_store: CorpusSearch::CacheStore.new)
    cache_store.absolute(CACHE_PATH)
  end

  def self.metadata(cache_store: CorpusSearch::CacheStore.new, index_path: nil)
    target = Pathname((index_path || path(cache_store: cache_store)).to_s).expand_path
    new(cache_store: cache_store, logger: nil).send(:current_metadata, target)
  end

  def self.current?(cache_store: CorpusSearch::CacheStore.new, snapshot: EastAsianAuthorityUpdater.current(cache_store: cache_store), index_path: nil)
    new(cache_store: cache_store, logger: nil).current?(snapshot: snapshot, index_path: index_path)
  end

  def self.build_if_needed!(cache_store: CorpusSearch::CacheStore.new, snapshot: nil, logger: Rails.logger)
    new(cache_store: cache_store, logger: logger).build_if_needed!(snapshot: snapshot)
  end

  def initialize(cache_store:, logger: nil)
    @cache_store = cache_store
    @logger = logger
  end

  def current?(snapshot:, index_path: nil)
    target = Pathname((index_path || self.class.path(cache_store: @cache_store)).to_s).expand_path
    return false unless target.file?

    metadata = current_metadata(target)
    metadata["version"].to_i == VERSION && metadata["fingerprint"].to_s == source_fingerprint(snapshot)
  rescue StandardError
    false
  end

  def build_if_needed!(snapshot: nil)
    snapshot ||= EastAsianAuthorityUpdater.current(cache_store: @cache_store)
    target = self.class.path(cache_store: @cache_store)
    fingerprint = source_fingerprint(snapshot)
    metadata = current_metadata(target)
    if target.file? && metadata["version"].to_i == VERSION && metadata["fingerprint"].to_s == fingerprint
      return Result.new(
        status: :current,
        path: target.to_s,
        fingerprint: fingerprint,
        counts: count_metadata(metadata),
        message: "Historical supplementary/East Asian authority index is current."
      )
    end

    rebuild!(target, fingerprint, snapshot)
  rescue StandardError => e
    @logger&.warn("[authority] historical authority index build failed: #{e.class}: #{e.message}")
    if target&.file?
      Result.new(
        status: :stale,
        path: target.to_s,
        fingerprint: current_metadata(target)["fingerprint"].to_s,
        counts: {},
        message: "Historical authority rebuild failed; retaining previous cache (#{e.class}: #{e.message})."
      )
    else
      Result.new(status: :unavailable, path: nil, fingerprint: nil, counts: {}, message: "Historical authority index unavailable: #{e.class}: #{e.message}")
    end
  end

  private

  def rebuild!(target, fingerprint, snapshot)
    require "sqlite3"

    FileUtils.mkdir_p(target.dirname)
    temporary = target.dirname.join(".#{target.basename}.build-#{Process.pid}-#{SecureRandom.hex(5)}")
    FileUtils.rm_f(temporary)
    db = SQLite3::Database.new(temporary.to_s)
    db.busy_timeout = 10_000
    db.execute_batch <<~SQL
      PRAGMA journal_mode=OFF;
      PRAGMA synchronous=OFF;
      PRAGMA temp_store=MEMORY;

      CREATE TABLE metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );

      CREATE TABLE people (
        source TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        country TEXT,
        label TEXT,
        local_label TEXT,
        romanized TEXT,
        year_start INTEGER,
        year_end INTEGER,
        date_label TEXT,
        polity TEXT,
        roles TEXT,
        places TEXT,
        source_url TEXT,
        source_citations TEXT,
        chronology_confidence TEXT,
        external_ids TEXT,
        shang_diviner INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (source, entity_id)
      ) WITHOUT ROWID;

      CREATE TABLE names (
        prefix TEXT NOT NULL,
        name_length INTEGER NOT NULL,
        name_chn TEXT NOT NULL,
        source TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        primary_name INTEGER NOT NULL DEFAULT 0,
        explicit_name INTEGER NOT NULL DEFAULT 0,
        derivation TEXT NOT NULL,
        PRIMARY KEY (prefix, name_chn, source, entity_id)
      ) WITHOUT ROWID;

      CREATE INDEX names_by_exact ON names(name_chn, name_length);

      CREATE TABLE eras (
        source TEXT NOT NULL,
        era_id TEXT NOT NULL,
        country TEXT,
        origin_country TEXT,
        label TEXT,
        local_label TEXT,
        start_date TEXT,
        end_date TEXT,
        start_year INTEGER,
        end_year INTEGER,
        epoch_start_year INTEGER,
        local_use_start_year INTEGER,
        local_use_end_year INTEGER,
        adopted_from_foreign INTEGER NOT NULL DEFAULT 0,
        polities_json TEXT,
        source_url TEXT,
        source_note TEXT,
        provenance_json TEXT,
        PRIMARY KEY (source, era_id)
      ) WITHOUT ROWID;

      CREATE TABLE era_names (
        prefix TEXT NOT NULL,
        name_length INTEGER NOT NULL,
        name_chn TEXT NOT NULL,
        source TEXT NOT NULL,
        era_id TEXT NOT NULL,
        explicit_name INTEGER NOT NULL DEFAULT 0,
        derivation TEXT NOT NULL,
        PRIMARY KEY (prefix, name_chn, source, era_id)
      ) WITHOUT ROWID;

      CREATE INDEX era_names_by_exact ON era_names(name_chn, name_length);

      CREATE TABLE era_rulers (
        era_source TEXT NOT NULL,
        era_id TEXT NOT NULL,
        ruler_source TEXT NOT NULL,
        ruler_id TEXT NOT NULL,
        PRIMARY KEY (era_source, era_id, ruler_source, ruler_id)
      ) WITHOUT ROWID;
    SQL

    counts = Hash.new(0)
    expander = AuthorityNameExpander.new
    db.transaction do
      import_supplementary!(db, expander, counts) if SUPPLEMENTARY_SOURCE_PATH.file?
      import_curated_eras!(db, expander, counts) if CURATED_ERA_SOURCE_PATH.file?
      import_east_asia!(db, snapshot, expander, counts) if snapshot.is_a?(Hash)
      write_metadata!(db, fingerprint, snapshot, counts)
    end
    db.execute("PRAGMA optimize")
    db.close
    db = nil

    File.rename(temporary, target)
    Result.new(
      status: :rebuilt,
      path: target.to_s,
      fingerprint: fingerprint,
      counts: counts.to_h,
      message: "Built historical authority index: #{counts['people']} people, #{counts['names']} names, #{counts['eras']} eras."
    )
  ensure
    db&.close rescue nil
    FileUtils.rm_f(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
  end

  def import_supplementary!(db, expander, counts)
    require "roo"

    workbook = Roo::Excelx.new(SUPPLEMENTARY_SOURCE_PATH.to_s)
    SUPPLEMENTARY_SHEETS.each do |sheet_name|
      next unless workbook.sheets.include?(sheet_name)

      sheet = workbook.sheet(sheet_name)
      headers = sheet.row(1).map { |value| value.to_s.strip }
      missing = REQUIRED_HEADERS - headers
      raise "#{sheet_name} is missing required columns: #{missing.join(', ')}" if missing.any?

      (2..sheet.last_row.to_i).each do |row_number|
        values = sheet.row(row_number)
        row = headers.each_with_index.to_h { |header, index| [header, values[index]] }
        next if row.except("person_id").values.all? { |value| blank_cell?(value) }

        person_id = normalize_identifier(row["person_id"])
        name_han = cell_text(row["name_han"])
        raise "#{sheet_name} row #{row_number}: person_id is required" if person_id.empty?
        raise "#{sheet_name} row #{row_number}: name_han is required" if name_han.empty?

        entity_id = "#{sheet_name}:#{person_id}"
        roles = cell_text(row["roles"])
        shang_diviner = sheet_name == "Shang" && roles.include?("巫") ? 1 : 0
        db.execute(
          <<~SQL,
            INSERT INTO people (
              source, entity_id, country, label, local_label, romanized,
              year_start, year_end, date_label, polity, roles, places,
              source_url, source_citations, chronology_confidence, external_ids, shang_diviner
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          SQL
          [
            "fanya_supplementary", entity_id, sheet_name == "Xia" ? "China" : "China",
            name_han, nil, cell_text(row["primary_name"]).presence,
            normalize_year(row["year_start"]), normalize_year(row["year_end"]),
            cell_text(row["date_label"]).presence, cell_text(row["polity"]).presence,
            roles.presence, cell_text(row["places"]).presence, "viewer/data/shang_people.xlsx",
            cell_text(row["source_citations"]).presence, nil, cell_text(row["external_ids"]).presence,
            shang_diviner
          ]
        )
        counts["people"] += 1
        counts["supplementary_people"] += 1
        counts["shang_diviners"] += 1 if shang_diviner == 1

        explicit_names = [name_han, *split_aliases(row["aliases"])].uniq
        insert_person_names!(db, "fanya_supplementary", entity_id, explicit_names, name_han, expander, counts)
      end
    end
  ensure
    workbook&.close rescue nil
  end

  def import_curated_eras!(db, expander, counts)
    payload = JSON.parse(CURATED_ERA_SOURCE_PATH.read(encoding: "bom|utf-8"))
    sources = Array(payload["sources"]).to_h { |source| [source["id"].to_s, source] }

    Array(payload["eras"]).each do |era|
      era_id = era["id"].to_s
      next if era_id.empty?

      era_source = era["source"].to_s.presence || "fanya_curated_era"
      source_citations = Array(era["source_ids"]).filter_map do |source_id|
        source = sources[source_id.to_s]
        next unless source

        [source["citation"], source["url"]].compact.map(&:to_s).reject(&:empty?).join(" ")
      end
      db.execute(
        <<~SQL,
          INSERT OR REPLACE INTO eras (
            source, era_id, country, origin_country, label, local_label, start_date, end_date,
            start_year, end_year, epoch_start_year, local_use_start_year, local_use_end_year, adopted_from_foreign,
            polities_json, source_url, source_note, provenance_json
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        [
          era_source, era_id, era["country"], era["origin_country"], era["label"], era["local_label"],
          era["start_date"], era["end_date"], era["start_year"], era["end_year"], era["epoch_start_year"],
          era["local_use_start_year"], era["local_use_end_year"], era["adopted_from_foreign"] ? 1 : 0,
          JSON.generate(Array(era["polities"])), era["source_url"], era["source_note"],
          JSON.generate(source_citations)
        ]
      )
      counts["eras"] += 1
      counts["curated_eras"] += 1
      counts["eras_#{era['country'].to_s.downcase}"] += 1 if era["country"].present?
      counts["era_epochs"] += 1 if era["epoch_start_year"].present?
      counts["era_local_use_intervals"] += 1 if era["local_use_start_year"].present? || era["local_use_end_year"].present?
      insert_era_names!(db, era_source, era_id, Array(era["han_names"]), expander, counts)
    end
  end

  def import_east_asia!(db, snapshot, expander, counts)
    ruler_sources = Array(snapshot["rulers"]).to_h do |ruler|
      [ruler["qid"].to_s, ruler["source"].to_s.presence || "wikidata_east_asia"]
    end

    Array(snapshot["rulers"]).each do |ruler|
      qid = ruler["qid"].to_s
      next if qid.empty?

      ruler_source = ruler["source"].to_s.presence || "wikidata_east_asia"
      db.execute(
        <<~SQL,
          INSERT OR REPLACE INTO people (
            source, entity_id, country, label, local_label, romanized,
            year_start, year_end, date_label, polity, roles, places,
            source_url, source_citations, chronology_confidence, external_ids, shang_diviner
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
        SQL
        [
          ruler_source, qid, ruler["country"], ruler["label"], ruler["local_label"],
          Array(ruler["readings"]).first, ruler["reign_start_year"], ruler["reign_end_year"],
          reign_label(ruler), Array(ruler["polities"]).join("; ").presence || ruler["country"].to_s.presence,
          "ruler", nil, ruler["source_url"], ruler_source_citations(ruler),
          ruler["chronology_confidence"], qid
        ]
      )
      counts["people"] += 1
      counts["east_asia_rulers"] += 1
      counts["traditional_ruler_chronologies"] += 1 if ruler["chronology_confidence"].present?
      counts["rulers_#{ruler['country'].to_s.downcase}"] += 1 if ruler["country"].present?
      names = Array(ruler["han_names"]).map(&:to_s).reject(&:empty?).uniq
      insert_person_names!(db, ruler_source, qid, names, names.first, expander, counts)
    end

    Array(snapshot["eras"]).each do |era|
      qid = era["qid"].to_s
      next if qid.empty?

      era_source = era["source"].to_s.presence || "wikidata_east_asia"
      db.execute(
        <<~SQL,
          INSERT OR REPLACE INTO eras (
            source, era_id, country, origin_country, label, local_label, start_date, end_date,
            start_year, end_year, epoch_start_year, local_use_start_year, local_use_end_year, adopted_from_foreign,
            polities_json, source_url, source_note, provenance_json
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        [
          era_source, qid, era["country"], era["origin_country"], era["label"], era["local_label"],
          era["start_date"], era["end_date"], era["start_year"], era["end_year"], era["epoch_start_year"],
          era["local_use_start_year"], era["local_use_end_year"], era["adopted_from_foreign"] ? 1 : 0,
          JSON.generate(Array(era["polities"])), era["source_url"], era_source_note(era),
          JSON.generate(Array(era["provenance"]))
        ]
      )
      counts["eras"] += 1
      counts["east_asia_eras"] += 1
      counts["eras_#{era['country'].to_s.downcase}"] += 1 if era["country"].present?
      counts["era_epochs"] += 1 if era["epoch_start_year"].present?
      counts["era_local_use_intervals"] += 1 if era["local_use_start_year"].present? || era["local_use_end_year"].present?
      counts["era_foreign_adoptions"] += 1 if era["adopted_from_foreign"]
      insert_era_names!(db, era_source, qid, Array(era["han_names"]), expander, counts)
      Array(era["ruler_qids"]).each do |ruler_id|
        ruler_id = ruler_id.to_s
        next if ruler_id.empty?

        db.execute(
          "INSERT OR IGNORE INTO era_rulers (era_source, era_id, ruler_source, ruler_id) VALUES (?, ?, ?, ?)",
          [era_source, qid, ruler_sources[ruler_id] || "wikidata_east_asia", ruler_id]
        )
      end
    end
  end

  def insert_person_names!(db, source, entity_id, explicit_names, primary_name, expander, counts)
    records = expanded_name_records(explicit_names, primary_name, expander)
    records.each do |record|
      name = record.fetch(:name)
      length = name.each_char.count
      next if length.zero? || length > AuthorityNameExpander::MAX_NAME_LENGTH
      prefix = name.each_char.take([2, length].min).join
      db.execute(
        <<~SQL,
          INSERT OR REPLACE INTO names (
            prefix, name_length, name_chn, source, entity_id,
            primary_name, explicit_name, derivation
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        [prefix, length, name, source, entity_id, record[:primary] ? 1 : 0, record[:explicit] ? 1 : 0, record[:derivation]]
      )
      counts["names"] += 1
      counts[record[:explicit] ? "explicit_names" : "derived_names"] += 1
    end
  end

  def insert_era_names!(db, source, era_id, names, expander, counts)
    expanded_name_records(names, names.first, expander).each do |record|
      name = record.fetch(:name)
      length = name.each_char.count
      next if length < 2 || length > AuthorityNameExpander::MAX_NAME_LENGTH
      prefix = name.each_char.take(2).join
      db.execute(
        "INSERT OR REPLACE INTO era_names (prefix, name_length, name_chn, source, era_id, explicit_name, derivation) VALUES (?, ?, ?, ?, ?, ?, ?)",
        [prefix, length, name, source, era_id, record[:explicit] ? 1 : 0, record[:derivation]]
      )
      counts["era_names"] += 1
      counts[record[:explicit] ? "explicit_era_names" : "derived_era_names"] += 1
    end
  end

  def ruler_source_citations(ruler)
    lines = Array(ruler["provenance"]).map(&:to_s).reject(&:empty?)
    if ruler["chronology_note"].present?
      lines << ruler["chronology_note"].to_s
    end
    if ruler["reign_date_conflict"].is_a?(Hash) && ruler["reign_date_conflict"].any?
      lines << "Reign-date source conflict retained: #{JSON.generate(ruler['reign_date_conflict'])}"
    end
    lines.join("\n").presence
  end

  def era_source_note(era)
    lines = [era["source_note"].to_s].reject(&:empty?)
    if era["date_conflict"].is_a?(Hash) && era["date_conflict"].any?
      lines << "Era-date source conflict retained: #{JSON.generate(era['date_conflict'])}"
    end
    lines.join("\n").presence
  end

  def expanded_name_records(names, primary_name, expander)
    output = {}
    Array(names).map(&:to_s).map(&:strip).reject(&:empty?).uniq.each do |name|
      next unless han_name?(name)
      output[name] ||= { name: name, primary: name == primary_name, explicit: true, derivation: "explicit" }
      expander.expand(name).each do |form|
        output[form.name] ||= { name: form.name, primary: false, explicit: false, derivation: form.derivation }
      end
    end
    output.values
  end

  def source_fingerprint(snapshot)
    digest = Digest::SHA256.new
    digest << "historical-authority-v#{VERSION}\0"
    if SUPPLEMENTARY_SOURCE_PATH.file?
      digest << Digest::SHA256.file(SUPPLEMENTARY_SOURCE_PATH).hexdigest
    else
      digest << "no-supplementary-workbook"
    end
    digest << "\0"
    if CURATED_ERA_SOURCE_PATH.file?
      digest << Digest::SHA256.file(CURATED_ERA_SOURCE_PATH).hexdigest
    else
      digest << "no-curated-era-source"
    end
    digest << "\0"
    digest << Digest::SHA256.hexdigest(JSON.generate(snapshot || {}))
    digest << "\0"
    digest << CorpusSearch::CharacterEquivalenceRegistry.version_for("broad")
    digest.hexdigest
  end

  def write_metadata!(db, fingerprint, snapshot, counts)
    values = {
      "version" => VERSION.to_s,
      "fingerprint" => fingerprint,
      "built_at_utc" => Time.now.utc.iso8601,
      "supplementary_filename" => SUPPLEMENTARY_SOURCE_PATH.file? ? SUPPLEMENTARY_SOURCE_PATH.basename.to_s : "",
      "supplementary_sha256" => SUPPLEMENTARY_SOURCE_PATH.file? ? Digest::SHA256.file(SUPPLEMENTARY_SOURCE_PATH).hexdigest : "",
      "curated_era_filename" => CURATED_ERA_SOURCE_PATH.file? ? CURATED_ERA_SOURCE_PATH.basename.to_s : "",
      "curated_era_sha256" => CURATED_ERA_SOURCE_PATH.file? ? Digest::SHA256.file(CURATED_ERA_SOURCE_PATH).hexdigest : "",
      "east_asia_snapshot_version" => snapshot.to_h["version"].to_s,
      "east_asia_generated_at_utc" => snapshot.to_h["generated_at_utc"].to_s,
      "east_asia_snapshot_sha256" => Digest::SHA256.hexdigest(JSON.generate(snapshot || {})),
      "east_asia_wikidata_license" => snapshot.to_h["wikidata_license"].to_s,
      "east_asia_wikipedia_license" => snapshot.to_h["wikipedia_discovery_license"].to_s,
      "east_asia_sources_json" => JSON.generate(snapshot.to_h["sources"] || {}),
      "equivalence_version" => CorpusSearch::CharacterEquivalenceRegistry.version_for("broad")
    }.merge(counts.transform_values(&:to_s))
    values.each do |key, value|
      db.execute("INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)", [key, value.to_s])
    end
  end

  def current_metadata(path)
    return {} unless path.file?
    require "sqlite3"
    db = SQLite3::Database.new(path.to_s, readonly: true)
    db.execute("SELECT key, value FROM metadata").to_h
  rescue SQLite3::Exception, SystemCallError
    {}
  ensure
    db&.close
  end

  def count_metadata(metadata)
    %w[
      people names eras era_names supplementary_people curated_eras east_asia_rulers east_asia_eras
      shang_diviners explicit_names derived_names explicit_era_names derived_era_names
      rulers_japan rulers_korea rulers_vietnam eras_japan eras_korea eras_vietnam
      era_epochs era_local_use_intervals era_foreign_adoptions traditional_ruler_chronologies
    ].to_h { |key| [key, metadata[key].to_i] }
  end

  def split_aliases(value)
    cell_text(value).split(/[\n,，;；]+/).map(&:strip).reject(&:empty?)
  end

  def han_name?(value)
    chars = value.to_s.each_char.to_a
    chars.any? && chars.length <= AuthorityNameExpander::MAX_NAME_LENGTH && chars.all? { |char| char.match?(/\p{Han}/) }
  end

  def reign_label(ruler)
    start_year = ruler["reign_start_year"]
    end_year = ruler["reign_end_year"]
    return nil unless start_year || end_year
    [start_year, end_year].compact.join("–")
  end

  def normalize_identifier(value)
    return value.to_i.to_s if value.is_a?(Numeric) && value.to_f.finite? && value.to_f == value.to_i
    cell_text(value)
  end

  def normalize_year(value)
    return value.to_i if value.is_a?(Numeric) && value.to_f.finite? && value.to_f == value.to_i
    text = cell_text(value)
    Integer(text) if text.match?(/\A-?\d+\z/)
  rescue ArgumentError, TypeError
    nil
  end

  def cell_text(value)
    value.nil? ? "" : value.to_s.strip
  end

  def blank_cell?(value)
    value.nil? || value.to_s.strip.empty?
  end
end
