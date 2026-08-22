# frozen_string_literal: true

require "digest"
require "fileutils"
require "pathname"
require "securerandom"
require "time"

# Compact CBDB name-pointer cache. Authority records remain in the CBDB SQLite;
# this cache stores only the Han name, entity kind, entity id and primary/alias
# flag needed to find relevant source rows quickly during annotation.
class CbdbLookupIndex
  VERSION = 1
  CACHE_PATH = "cbdb-lookup-v1.sqlite3"

  Result = Data.define(:status, :path, :source_sha256, :counts, :message) do
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

  def self.build_if_needed!(source_path:, source_release: {}, cache_store: CorpusSearch::CacheStore.new, logger: Rails.logger)
    new(cache_store: cache_store, logger: logger).build_if_needed!(source_path: source_path, source_release: source_release)
  end

  def initialize(cache_store:, logger: nil)
    @cache_store = cache_store
    @logger = logger
  end

  def build_if_needed!(source_path:, source_release: {})
    source = Pathname(source_path.to_s).expand_path
    raise "CBDB SQLite does not exist: #{source}" unless source.file?

    sha = source_release.to_h["sha256"].to_s
    sha = Digest::SHA256.file(source).hexdigest if sha.empty?
    target = self.class.path(cache_store: @cache_store)
    metadata = current_metadata(target)
    if target.file? && metadata["version"].to_i == VERSION && metadata["source_sha256"].to_s == sha
      return Result.new(
        status: :current,
        path: target.to_s,
        source_sha256: sha,
        counts: count_metadata(metadata),
        message: "CBDB lookup cache is current."
      )
    end

    rebuild!(source, target, sha, source_release)
  rescue StandardError => e
    @logger&.warn("[cbdb] lookup index build failed: #{e.class}: #{e.message}")
    if target&.file?
      Result.new(status: :stale, path: target.to_s, source_sha256: current_metadata(target)["source_sha256"].to_s, counts: {}, message: "CBDB lookup rebuild failed; retaining previous cache (#{e.class}: #{e.message}).")
    else
      Result.new(status: :unavailable, path: nil, source_sha256: nil, counts: {}, message: "CBDB lookup unavailable: #{e.class}: #{e.message}")
    end
  end

  private

  def rebuild!(source, target, sha, source_release)
    require "sqlite3"

    FileUtils.mkdir_p(target.dirname)
    temporary = target.dirname.join(".#{target.basename}.build-#{Process.pid}-#{SecureRandom.hex(5)}")
    FileUtils.rm_f(temporary)

    source_db = SQLite3::Database.new(source.to_s, readonly: true)
    source_db.results_as_hash = true
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

      CREATE TABLE names (
        prefix TEXT NOT NULL,
        name_length INTEGER NOT NULL,
        name_chn TEXT NOT NULL,
        kind TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        primary_name INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (prefix, name_chn, kind, entity_id)
      ) WITHOUT ROWID;

      CREATE INDEX names_exact ON names(name_chn, name_length, kind);
    SQL

    counts = Hash.new(0)
    insert_statement = db.prepare(
      "INSERT OR IGNORE INTO names (prefix, name_length, name_chn, kind, entity_id, primary_name) VALUES (?, ?, ?, ?, ?, ?)"
    )

    db.transaction do
      import_people!(source_db, insert_statement, counts)
      import_places!(source_db, insert_statement, counts)
      import_offices!(source_db, insert_statement, counts)
      values = {
        "version" => VERSION.to_s,
        "source_sha256" => sha,
        "source_filename" => source.basename.to_s,
        "source_generated_at_utc" => source_release.to_h["generated_at_utc"].to_s,
        "built_at_utc" => Time.now.utc.iso8601
      }.merge(counts.transform_values(&:to_s))
      values.each { |key, value| db.execute("INSERT INTO metadata (key, value) VALUES (?, ?)", [key, value.to_s]) }
    end
    insert_statement.close
    insert_statement = nil
    db.close
    db = nil
    source_db.close
    source_db = nil

    File.rename(temporary, target)
    Result.new(
      status: :rebuilt,
      path: target.to_s,
      source_sha256: sha,
      counts: counts.to_h,
      message: "Built CBDB lookup cache with #{counts['names']} name pointers."
    )
  ensure
    insert_statement&.close rescue nil
    db&.close rescue nil
    source_db&.close rescue nil
    FileUtils.rm_f(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
  end

  def import_people!(source_db, statement, counts)
    return unless table_exists?(source_db, "BIOG_MAIN")

    columns = table_columns(source_db, "BIOG_MAIN")
    id_column = choose_column(columns, %w[c_personid person_id])
    name_column = choose_column(columns, %w[c_name_chn c_name_ch name_chn])
    import_name_query!(source_db, statement, counts, table: "BIOG_MAIN", id_column: id_column, name_column: name_column, kind: "person", primary: true)

    return unless table_exists?(source_db, "ALTNAME_DATA")

    alt_columns = table_columns(source_db, "ALTNAME_DATA")
    alt_id = choose_column(alt_columns, %w[c_personid person_id])
    alt_name = choose_column(alt_columns, %w[c_alt_name_chn c_altname_chn c_name_chn alt_name_chn])
    import_name_query!(source_db, statement, counts, table: "ALTNAME_DATA", id_column: alt_id, name_column: alt_name, kind: "person", primary: false)
  end

  def import_places!(source_db, statement, counts)
    return unless table_exists?(source_db, "ADDR_CODES")

    columns = table_columns(source_db, "ADDR_CODES")
    id_column = choose_column(columns, %w[c_addr_id c_addrid addr_id])
    name_column = choose_column(columns, %w[c_name_chn c_addr_chn c_addr_name_chn name_chn])
    import_name_query!(source_db, statement, counts, table: "ADDR_CODES", id_column: id_column, name_column: name_column, kind: "place", primary: true)
  end

  def import_offices!(source_db, statement, counts)
    return unless table_exists?(source_db, "OFFICE_CODES")

    columns = table_columns(source_db, "OFFICE_CODES")
    id_column = choose_column(columns, %w[c_office_id c_officeid office_id])
    name_column = choose_column(columns, %w[c_office_chn c_name_chn c_office_name_chn office_chn])
    import_name_query!(source_db, statement, counts, table: "OFFICE_CODES", id_column: id_column, name_column: name_column, kind: "office", primary: true)
  end

  def import_name_query!(source_db, statement, counts, table:, id_column:, name_column:, kind:, primary:)
    return unless id_column && name_column

    quoted_table = quote_identifier(table)
    quoted_id = quote_identifier(id_column)
    quoted_name = quote_identifier(name_column)
    source_db.execute("SELECT #{quoted_id} AS entity_id, #{quoted_name} AS name_chn FROM #{quoted_table} WHERE #{quoted_name} IS NOT NULL") do |row|
      name = row["name_chn"].to_s.strip
      entity_id = row["entity_id"].to_s.strip
      next unless searchable_name?(name) && !entity_id.empty?

      length = name.each_char.count
      prefix = name.each_char.take([2, length].min).join
      statement.execute(prefix, length, name, kind, entity_id, primary ? 1 : 0).close
      counts["names"] += 1 # pointer-attempt count; INSERT OR IGNORE handles duplicate rows
      counts["#{kind}_names"] += 1
    end
  end

  def searchable_name?(name)
    chars = name.to_s.each_char.to_a
    chars.any? && chars.length <= 16 && chars.all? { |character| character.match?(/\p{Han}/) }
  end

  def table_exists?(db, table)
    db.get_first_value("SELECT 1 FROM sqlite_master WHERE type='table' AND name = ? LIMIT 1", [table]).to_i == 1
  end

  def table_columns(db, table)
    db.execute("PRAGMA table_info(#{quote_identifier(table)})").map { |row| row["name"].to_s }
  end

  def choose_column(columns, candidates)
    lookup = columns.to_h { |column| [column.downcase, column] }
    candidates.each do |candidate|
      found = lookup[candidate.downcase]
      return found if found
    end
    nil
  end

  def quote_identifier(value)
    %Q{"#{value.to_s.gsub('"', '""')}"}
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
    %w[names person_names place_names office_names].to_h { |key| [key, metadata[key].to_i] }
  end
end
