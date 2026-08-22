# frozen_string_literal: true

require "date"
require "digest"
require "fileutils"
require "pathname"
require "securerandom"
require "time"

# Rebuildable authority cache for the project-maintained Shang/Xia workbook.
#
# viewer/data/shang_people.xlsx is the source of truth. This SQLite file is a
# disposable runtime index containing the workbook rows plus generated search
# aliases. Deleting it loses no scholarly data; the maintenance task rebuilds it
# from the workbook.
class SupplementaryAuthorityIndex
  VERSION = 1
  SOURCE_PATH = Rails.root.join("data", "shang_people.xlsx")
  CACHE_PATH = "supplementary-authority-v1.sqlite3"
  SOURCE_SHEETS = %w[Shang Xia].freeze
  REQUIRED_HEADERS = %w[
    person_id primary_name name_han aliases polity period year_start year_end
    date_label roles places source_citations external_ids notes
  ].freeze

  Result = Data.define(:status, :path, :source_sha256, :counts, :message) do
    def available? = path.present? && File.file?(path)
    def rebuilt? = status == :rebuilt
  end

  def self.build_if_needed!(source_path: SOURCE_PATH, cache_store: CorpusSearch::CacheStore.new, logger: Rails.logger)
    new(source_path: source_path, cache_store: cache_store, logger: logger).build_if_needed!
  end

  def self.path(cache_store: CorpusSearch::CacheStore.new)
    cache_store.absolute(CACHE_PATH)
  end

  def self.metadata(cache_store: CorpusSearch::CacheStore.new)
    new(source_path: SOURCE_PATH, cache_store: cache_store, logger: nil)
      .send(:current_metadata, cache_store.absolute(CACHE_PATH))
  end

  def self.current?(source_path: SOURCE_PATH, cache_store: CorpusSearch::CacheStore.new, index_path: nil)
    source = Pathname(source_path.to_s).expand_path
    target = Pathname((index_path || cache_store.absolute(CACHE_PATH)).to_s).expand_path
    return false unless source.file? && target.file?

    metadata = new(source_path: source, cache_store: cache_store, logger: nil)
      .send(:current_metadata, target)
    return false unless metadata["version"].to_i == VERSION
    return false unless metadata["source_sha256"].to_s == Digest::SHA256.file(source).hexdigest

    metadata["equivalence_version"].to_s == CorpusSearch::CharacterEquivalenceRegistry.version_for("broad")
  rescue StandardError
    false
  end

  def initialize(source_path:, cache_store:, logger: nil)
    @source_path = Pathname(source_path.to_s).expand_path
    @cache_store = cache_store
    @logger = logger
  end

  def build_if_needed!
    return unavailable("Supplementary authority workbook is missing: #{@source_path}") unless @source_path.file?

    require "sqlite3"

    source_sha = Digest::SHA256.file(@source_path).hexdigest
    equivalence_version = CorpusSearch::CharacterEquivalenceRegistry.version_for("broad")
    target = @cache_store.absolute(CACHE_PATH)
    current = current_metadata(target)

    if current["version"].to_i == VERSION &&
       current["source_sha256"].to_s == source_sha &&
       current["equivalence_version"].to_s == equivalence_version
      return Result.new(
        status: :current,
        path: target.to_s,
        source_sha256: source_sha,
        counts: count_metadata(current),
        message: "Supplementary Shang/Xia authority index is current."
      )
    end

    rebuild!(target, source_sha, equivalence_version)
  rescue StandardError => e
    @logger&.warn("[authority] supplementary index build failed: #{e.class}: #{e.message}")
    target ||= @cache_store.absolute(CACHE_PATH)
    if target.file?
      Result.new(
        status: :stale,
        path: target.to_s,
        source_sha256: current_metadata(target)["source_sha256"].to_s,
        counts: {},
        message: "Supplementary authority rebuild failed; keeping the previous cache (#{e.class}: #{e.message})."
      )
    else
      unavailable("Supplementary authority index is unavailable: #{e.class}: #{e.message}")
    end
  end

  private

  def rebuild!(target, source_sha, equivalence_version)
    require "roo"
    require "sqlite3"

    FileUtils.mkdir_p(target.dirname)
    temporary = target.dirname.join(".#{target.basename}.build-#{Process.pid}-#{SecureRandom.hex(5)}")
    FileUtils.rm_f(temporary)

    workbook = Roo::Excelx.new(@source_path.to_s)
    expander = AuthorityNameExpander.new
    db = SQLite3::Database.new(temporary.to_s)
    db.busy_timeout = 10_000
    db.execute_batch <<~SQL
      PRAGMA journal_mode=OFF;
      PRAGMA synchronous=OFF;
      PRAGMA temp_store=MEMORY;
      PRAGMA foreign_keys=OFF;

      CREATE TABLE metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );

      CREATE TABLE people (
        source_sheet TEXT NOT NULL,
        person_id TEXT NOT NULL,
        primary_name TEXT,
        name_han TEXT NOT NULL,
        aliases TEXT,
        polity TEXT,
        period TEXT,
        year_start INTEGER,
        year_end INTEGER,
        date_label TEXT,
        roles TEXT,
        places TEXT,
        source_citations TEXT,
        external_ids TEXT,
        notes TEXT,
        shang_diviner INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (source_sheet, person_id)
      ) WITHOUT ROWID;

      CREATE TABLE names (
        prefix TEXT NOT NULL,
        name_length INTEGER NOT NULL,
        name_chn TEXT NOT NULL,
        source_sheet TEXT NOT NULL,
        person_id TEXT NOT NULL,
        primary_name INTEGER NOT NULL DEFAULT 0,
        explicit_name INTEGER NOT NULL DEFAULT 0,
        derivation TEXT NOT NULL,
        PRIMARY KEY (prefix, name_chn, source_sheet, person_id)
      ) WITHOUT ROWID;
    SQL

    counts = Hash.new(0)
    seen_ids = {}
    db.transaction do
      people_statement = db.prepare(<<~SQL)
        INSERT INTO people (
          source_sheet, person_id, primary_name, name_han, aliases, polity, period,
          year_start, year_end, date_label, roles, places, source_citations,
          external_ids, notes, shang_diviner
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      names_statement = db.prepare(<<~SQL)
        INSERT OR REPLACE INTO names (
          prefix, name_length, name_chn, source_sheet, person_id,
          primary_name, explicit_name, derivation
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      SQL

      SOURCE_SHEETS.each do |sheet_name|
        raise "Missing authority worksheet: #{sheet_name}" unless workbook.sheets.include?(sheet_name)

        sheet = workbook.sheet(sheet_name)
        headers = sheet.row(1).map { |value| value.to_s.strip }
        missing = REQUIRED_HEADERS - headers
        raise "#{sheet_name} is missing required columns: #{missing.join(', ')}" if missing.any?

        (2..sheet.last_row.to_i).each do |row_number|
          values = sheet.row(row_number)
          next if values.all? { |value| blank_cell?(value) }

          row = headers.each_with_index.to_h { |header, index| [header, values[index]] }
          # The working workbook deliberately pre-numbers many empty rows. Treat
          # a row containing only person_id as an unused template row, while
          # still rejecting a genuinely populated authority record with no Han
          # identity. This lets the researcher keep extending the sheet without
          # the importer mistaking future placeholders for people.
          next if placeholder_row?(row)

          person_id = normalize_identifier(row["person_id"])
          name_han = cell_text(row["name_han"])
          raise "#{sheet_name} row #{row_number}: person_id is required" if person_id.blank?
          raise "#{sheet_name} row #{row_number}: name_han is required" if name_han.blank?

          unique_id = [sheet_name, person_id]
          raise "Duplicate supplementary authority id #{sheet_name}:#{person_id}" if seen_ids.key?(unique_id)
          seen_ids[unique_id] = true

          roles = cell_text(row["roles"])
          shang_diviner = sheet_name == "Shang" && roles.include?("巫") ? 1 : 0
          people_statement.execute(
            sheet_name,
            person_id,
            cell_text(row["primary_name"]).presence,
            name_han,
            cell_text(row["aliases"]).presence,
            cell_text(row["polity"]).presence,
            cell_text(row["period"]).presence,
            normalize_year(row["year_start"]),
            normalize_year(row["year_end"]),
            cell_text(row["date_label"]).presence,
            roles.presence,
            cell_text(row["places"]).presence,
            cell_text(row["source_citations"]).presence,
            cell_text(row["external_ids"]).presence,
            cell_text(row["notes"]).presence,
            shang_diviner
          )
          counts["people"] += 1
          counts["shang_diviners"] += 1 if shang_diviner == 1

          name_records = build_name_records(name_han, row["aliases"], expander)
          name_records.each_value do |record|
            name = record.fetch(:name)
            length = name.each_char.count
            prefix = name.each_char.take([length, 2].min).join
            names_statement.execute(
              prefix,
              length,
              name,
              sheet_name,
              person_id,
              record.fetch(:primary) ? 1 : 0,
              record.fetch(:explicit) ? 1 : 0,
              record.fetch(:derivation)
            )
            counts["names"] += 1
            counts[record.fetch(:explicit) ? "explicit_names" : "derived_names"] += 1
          end
        end
      end
    ensure
      people_statement&.close
      names_statement&.close
    end

    write_metadata!(db, source_sha, equivalence_version, counts)
    db.execute("PRAGMA optimize")
    db.close
    db = nil

    File.rename(temporary, target)
    Result.new(
      status: :rebuilt,
      path: target.to_s,
      source_sha256: source_sha,
      counts: counts.to_h,
      message: "Built supplementary authority index with #{counts['people']} people and #{counts['names']} searchable name forms."
    )
  ensure
    db&.close rescue nil
    workbook&.close rescue nil
    FileUtils.rm_f(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
  end

  def build_name_records(name_han, aliases, expander)
    explicit_names = [name_han, *split_aliases(aliases)].map(&:strip).reject(&:empty?).uniq
    output = {}

    explicit_names.each_with_index do |name, index|
      next unless searchable_han_name?(name)

      output[name] = {
        name: name,
        primary: index.zero?,
        explicit: true,
        derivation: index.zero? ? "name_han" : "explicit_alias"
      }
    end

    explicit_names.each do |name|
      next unless searchable_han_name?(name)

      expander.expand(name).each do |form|
        next if output.key?(form.name)

        output[form.name] = {
          name: form.name,
          primary: false,
          explicit: false,
          derivation: form.derivation
        }
      end
    end

    output
  end

  def split_aliases(value)
    cell_text(value).split(/[\n,，;；]+/).map(&:strip).reject(&:empty?)
  end

  def searchable_han_name?(value)
    chars = value.to_s.each_char.to_a
    chars.any? && chars.length <= AuthorityNameExpander::MAX_NAME_LENGTH && chars.all? { |char| char.match?(/\p{Han}/) }
  end

  def write_metadata!(db, source_sha, equivalence_version, counts)
    values = {
      "version" => VERSION.to_s,
      "source_sha256" => source_sha,
      "source_filename" => @source_path.basename.to_s,
      "equivalence_version" => equivalence_version,
      "built_at_utc" => Time.now.utc.iso8601,
      "retrieved_on" => Date.current.iso8601
    }.merge(counts.transform_values(&:to_s))

    statement = db.prepare("INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)")
    values.each { |key, value| statement.execute(key, value.to_s) }
  ensure
    statement&.close
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
    %w[people names explicit_names derived_names shang_diviners]
      .to_h { |key| [key, metadata[key].to_i] }
  end

  def placeholder_row?(row)
    row.except("person_id").values.all? { |value| blank_cell?(value) }
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

  def unavailable(message)
    Result.new(status: :unavailable, path: nil, source_sha256: nil, counts: {}, message: message)
  end
end
