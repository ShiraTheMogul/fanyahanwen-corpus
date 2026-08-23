# frozen_string_literal: true

require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "sqlite3"
require "time"

# Dedicated work/title catalogue for the chronological Corpus Viewer timeline.
#
# This index intentionally does not read CorpusSearch::Manifest. Full-text search
# is document-oriented; the catalogue is work-oriented. During maintenance this
# class reads only metadata.json records under each corpus root's existing clean
# tree, so metadata-only works are discoverable even when they have no searchable
# document body. Web requests query the resulting compact SQLite file.
class CorpusCatalogueIndex
  VERSION = 5
  DB_PATH = "work-catalogue-v5.sqlite3"
  DEFAULT_PER_PAGE = 100
  MAX_PER_PAGE = 250
  SKIP_DIRECTORIES = %w[
    raw variants variant translation translations reconstruction reconstructions
    normalisation normalisations normalization normalizations
    annotation annotations kanbun hanmun hanvan
  ].freeze

  class CacheMissing < StandardError; end

  Page = Data.define(:items, :page, :per_page, :total, :total_pages)

  attr_reader :generated_at, :normalisation_version, :work_count

  def self.load(root: Rails.configuration.x.corpus_root, cache_store: CorpusSearch::CacheStore.new)
    new(root: root, cache_store: cache_store).tap(&:load!)
  end

  def self.build!(root: Rails.configuration.x.corpus_root, cache_store: CorpusSearch::CacheStore.new, store: HistoricalAuthorityStore.default)
    new(root: root, cache_store: cache_store, store: store).build!
  end

  def initialize(root:, cache_store: CorpusSearch::CacheStore.new, store: nil)
    @root = Pathname(File.realpath(root.to_s))
    @cache_store = cache_store
    @path = cache_store.absolute(DB_PATH)
    @normaliser = AuthorityHanVariantRegistry.instance
    @date_resolver = store ? HistoricalDateResolver.new(store: store) : nil
    @generated_at = ""
    @normalisation_version = ""
    @work_count = 0
  end

  def load!
    raise CacheMissing, missing_message unless @path.file?

    with_database(readonly: true) do |db|
      metadata = db.execute("SELECT key, value FROM metadata").to_h { |row| [row["key"], row["value"]] }
      raise CacheMissing, missing_message unless metadata["version"].to_i == VERSION
      raise CacheMissing, missing_message unless metadata["corpus_root"].to_s == @root.to_s
      raise CacheMissing, missing_message unless metadata["normalisation_version"].to_s == @normaliser.version.to_s

      @generated_at = metadata["generated_at"].to_s
      @normalisation_version = metadata["normalisation_version"].to_s
      @work_count = metadata["work_count"].to_i
    end
    self
  rescue SQLite3::Exception
    raise CacheMissing, missing_message
  end

  def build!
    FileUtils.mkdir_p(@path.dirname)
    temporary = @path.dirname.join(".#{@path.basename}.#{$$}.#{SecureRandom.hex(6)}.tmp")
    FileUtils.rm_f(temporary)

    rows = scan_work_rows
    db = SQLite3::Database.new(temporary.to_s)
    db.results_as_hash = true
    db.execute("PRAGMA journal_mode = OFF")
    db.execute("PRAGMA synchronous = OFF")
    create_schema!(db)

    insert_work = db.prepare(<<~SQL)
      INSERT INTO works (
        work_key, work_id, display_title, base_title, folder_path,
        author, date_text, nation, corpus_root, macro_region, period,
        polity, region, year_start, year_end, sort_year, categories_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    SQL

    insert_key = db.prepare(<<~SQL)
      INSERT OR IGNORE INTO title_keys (work_key, title_key, key_kind) VALUES (?, ?, ?)
    SQL

    insert_person = db.prepare(<<~SQL)
      INSERT OR IGNORE INTO work_people (work_key, name_key, display_name, role) VALUES (?, ?, ?, ?)
    SQL

    db.transaction do
      rows.sort_by { |row| row.fetch("work_key") }.each do |row|
        work_key = row.fetch("work_key")
        insert_work.execute(
          work_key, row["work_id"], row.fetch("display_title"), row.fetch("base_title"), row.fetch("folder_path"),
          row["author"], row["date_text"], row["nation"], row["corpus_root"], row["macro_region"],
          row["period"], row["polity"], row["region"], row["year_start"], row["year_end"], row["sort_year"],
          JSON.generate(row["categories"])
        )
        variant_strings(row.fetch("display_title")).each { |key| insert_key.execute(work_key, key, "display") }
        variant_strings(row.fetch("base_title")).each { |key| insert_key.execute(work_key, key, "base") }
        Array(row["credits"]).each do |credit|
          person_name_keys(credit.fetch("name")).each do |name_key|
            Array(credit["roles"]).each do |role|
              insert_person.execute(work_key, name_key, credit.fetch("name"), role)
            end
          end
        end
      end

      {
        "version" => VERSION.to_s,
        "corpus_root" => @root.to_s,
        "normalisation_version" => @normaliser.version.to_s,
        "work_count" => rows.length.to_s,
        "generated_at" => Time.now.utc.iso8601
      }.each do |key, value|
        db.execute("INSERT INTO metadata (key, value) VALUES (?, ?)", [key, value])
      end
    end

    insert_work.close
    insert_work = nil
    insert_key.close
    insert_key = nil
    insert_person.close
    insert_person = nil
    db.execute("ANALYZE")
    db.close
    db = nil
    FileUtils.mv(temporary, @path)
    load!
  ensure
    insert_work&.close rescue nil
    insert_key&.close rescue nil
    insert_person&.close rescue nil
    db&.close rescue nil
    FileUtils.rm_f(temporary) if defined?(temporary) && temporary
  end

  def timeline(query: nil, order: "asc", geography: true, page: 1, per_page: DEFAULT_PER_PAGE)
    load! if @generated_at.empty?
    chosen_page = [integer_parameter(page, default: 1), 1].max
    chosen_per_page = [[integer_parameter(per_page, default: DEFAULT_PER_PAGE), 1].max, MAX_PER_PAGE].min
    direction = order.to_s == "desc" ? "desc" : "asc"
    text = query.to_s.strip

    rows = if text.empty?
      browse_rows(order: direction, geography: geography, page: chosen_page, per_page: chosen_per_page)
    else
      search_rows(text, order: direction, geography: geography, page: chosen_page, per_page: chosen_per_page)
    end

    if rows.empty? && chosen_page > 1
      return timeline(query: text, order: direction, geography: geography, page: 1, per_page: chosen_per_page)
    end

    total = rows.first ? rows.first["total_count"].to_i : 0
    total_pages = [(total.to_f / chosen_per_page).ceil, 1].max
    chosen_page = [chosen_page, total_pages].min

    Page.new(
      items: rows.map { |row| public_row(row) },
      page: chosen_page,
      per_page: chosen_per_page,
      total: total,
      total_pages: total_pages
    )
  rescue ArgumentError, TypeError
    Page.new(items: [], page: 1, per_page: DEFAULT_PER_PAGE, total: 0, total_pages: 1)
  end

  def works_for_person(names:, limit: 250)
    keys = person_name_keys(Array(names))
    return [] if keys.empty?

    placeholders = (["?"] * keys.length).join(",")
    chosen_limit = [[Integer(limit), 1].max, 1_000].min
    query_limit = chosen_limit * 20
    rows = with_database(readonly: true) do |db|
      db.execute(<<~SQL, [*keys, query_limit])
        SELECT works.*, work_people.role AS credit_role
        FROM work_people
        JOIN works ON works.work_key = work_people.work_key
        WHERE work_people.name_key IN (#{placeholders})
        ORDER BY CASE WHEN works.sort_year IS NULL THEN 1 ELSE 0 END, works.sort_year, works.display_title, work_people.role
        LIMIT ?
      SQL
    end

    rows.group_by { |row| row["work_key"] }.values.first(chosen_limit).map do |group|
      work = public_row(group.first)
      work["credit_roles"] = group.map { |row| row["credit_role"].to_s }.reject(&:empty?).uniq
      work
    end
  rescue ArgumentError, TypeError, SQLite3::Exception
    []
  end

  def works_for_author(names:, limit: 250)
    works_for_person(names: names, limit: limit).select { |work| Array(work["credit_roles"]).include?("author") }
  end

  def people_matching(query:, limit: 50)
    text = query.to_s.strip
    return [] if text.empty?

    key = text.unicode_normalize(:nfkc).downcase
    latin_key = key.gsub(/\p{Han}+/, " ").gsub(/[^\p{L}\p{N}]+/u, " ").strip
    contains = "%#{escape_like(text)}%"
    key_contains = "%#{escape_like(key)}%"
    latin_contains = "%#{escape_like(latin_key)}%"
    chosen_limit = [[Integer(limit), 1].max, 200].min
    with_database(readonly: true) do |db|
      rows = db.execute(<<~SQL, [text, key, latin_key, contains, key_contains, latin_contains, text, key, latin_key, chosen_limit])
        SELECT display_name, name_key, COUNT(DISTINCT work_key) AS work_count,
               GROUP_CONCAT(DISTINCT role) AS roles
        FROM work_people
        WHERE display_name = ? OR name_key = ? OR name_key = ?
           OR display_name LIKE ? ESCAPE '\\'
           OR name_key LIKE ? ESCAPE '\\'
           OR name_key LIKE ? ESCAPE '\\'
        GROUP BY display_name, name_key
        ORDER BY CASE WHEN display_name = ? OR name_key = ? OR name_key = ? THEN 0 ELSE 1 END,
                 work_count DESC, display_name
        LIMIT ?
      SQL
      rows.group_by { |row| row["display_name"].to_s }.map do |name, grouped|
        keys = grouped.map { |row| row["name_key"].to_s }.reject(&:empty?).uniq
        preferred_key = keys.min_by { |candidate| [candidate.match?(/\p{Han}/) ? 0 : 1, candidate.length, candidate] }
        {
          "name" => name,
          "name_key" => preferred_key.to_s,
          "work_count" => grouped.map { |row| row["work_count"].to_i }.max.to_i,
          "roles" => grouped.flat_map { |row| row["roles"].to_s.split(",") }.map(&:strip).reject(&:empty?).uniq
        }
      end.sort_by { |row| [-row["work_count"], row["name"]] }.first(chosen_limit)
    end
  rescue ArgumentError, TypeError, SQLite3::Exception
    []
  end

  def corpus_person(name)
    keys = person_name_keys(name)
    return nil if keys.empty?

    placeholders = (["?"] * keys.length).join(",")
    rows = with_database(readonly: true) do |db|
      db.execute(<<~SQL, keys)
        SELECT display_name, name_key, COUNT(DISTINCT work_key) AS work_count,
               GROUP_CONCAT(DISTINCT role) AS roles
        FROM work_people
        WHERE name_key IN (#{placeholders})
        GROUP BY display_name, name_key
        ORDER BY work_count DESC, display_name
      SQL
    end
    return nil if rows.empty?

    chosen_name = rows.first["display_name"].to_s
    grouped = rows.select { |row| row["display_name"].to_s == chosen_name }
    keys = grouped.map { |row| row["name_key"].to_s }.reject(&:empty?).uniq
    preferred_key = keys.min_by { |candidate| [candidate.match?(/\p{Han}/) ? 0 : 1, candidate.length, candidate] }
    {
      "name" => chosen_name,
      "name_key" => preferred_key.to_s,
      "work_count" => grouped.map { |row| row["work_count"].to_i }.max.to_i,
      "roles" => grouped.flat_map { |row| row["roles"].to_s.split(",") }.map(&:strip).reject(&:empty?).uniq
    }
  rescue SQLite3::Exception
    nil
  end

  private

  def scan_work_rows
    chosen = {}
    clean_roots.each do |clean_root|
      scan_clean_tree(clean_root) do |metadata_path|
        row = work_row_from(metadata_path)
        next unless row

        key = row.fetch("work_key")
        previous = chosen[key]
        chosen[key] = row if previous.nil? || (row_preference(row) <=> row_preference(previous)).negative?
      end
    end
    chosen.values
  end

  def clean_roots
    Dir.children(@root).sort.filter_map do |name|
      next if name.start_with?(".")
      next unless name.match?(/\p{Han}/)

      candidate = @root.join(name, "clean")
      candidate if candidate.directory?
    rescue SystemCallError
      nil
    end
  end

  def scan_clean_tree(clean_root, &block)
    stack = [clean_root]
    until stack.empty?
      directory = stack.pop
      begin
        entries = Dir.children(directory)
        metadata = directory.join("metadata.json")
        yield metadata if entries.include?("metadata.json") && metadata.file?

        entries.sort.reverse_each do |name|
          next if name.start_with?(".")
          next if name == "metadata.json"
          next if file_like_name?(name)
          next if SKIP_DIRECTORIES.include?(name.downcase)

          child = directory.join(name)
          begin
            stack << child if child.directory?
          rescue SystemCallError
            next
          end
        end
      rescue Errno::EACCES, Errno::ENOENT, Errno::EIO
        next
      end
    end
  end

  def file_like_name?(name)
    name.match?(/\.(?:txt|json|csv|tsv|xlsx|zip|gz|sqlite3?|db|md|html?|xml|yml|yaml|jpg|jpeg|png|webp|pdf)\z/i)
  end

  def work_row_from(metadata_path)
    metadata = read_metadata(metadata_path)
    return nil if metadata.empty?

    folder = metadata_path.dirname.relative_path_from(@root).to_s.tr("\\", "/")
    display_title = first_nonblank(metadata["display_title"], metadata["title"], metadata["work_base_title"], File.basename(folder))
    return nil if display_title.blank?

    base = base_title(first_nonblank(metadata["work_base_title"], display_title))
    work_id = integer_or_nil(metadata["work_id"])
    start_year = integer_or_nil(metadata["year_start"] || metadata["year"])
    end_year = integer_or_nil(metadata["year_end"] || metadata["year"])

    if start_year.nil? && end_year.nil? && metadata["date_label"].present? && @date_resolver
      resolution = @date_resolver.resolve(metadata: metadata)
      start_year = resolution&.year_start
      end_year = resolution&.year_end
    end

    start_year ||= end_year
    end_year ||= start_year
    sort_year = start_year || inferred_period_start(metadata, folder)
    categories = (Array(metadata["categories"]) + Array(metadata["source_categories"]))
      .map(&:to_s).map(&:strip).reject(&:empty?).uniq

    {
      "work_key" => work_id ? "work:#{work_id}" : "folder:#{folder}",
      "work_id" => work_id&.to_s,
      "display_title" => display_title,
      "base_title" => base,
      "folder_path" => folder,
      "author" => names_string(metadata["authors"]),
      "date_text" => metadata["date_label"].to_s.presence,
      "nation" => metadata["nation"].to_s.presence || metadata["corpus_root"].to_s.presence,
      "corpus_root" => metadata["corpus_root"].to_s.presence,
      "macro_region" => metadata["macro_region"].to_s.presence,
      "period" => metadata["period"].to_s.presence,
      "polity" => metadata["polity"].to_s.presence,
      "region" => metadata["region"].to_s.presence,
      "year_start" => start_year,
      "year_end" => end_year,
      "sort_year" => sort_year,
      "categories" => categories,
      "credits" => credit_entries(metadata)
    }
  rescue JSON::ParserError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError, SystemCallError
    nil
  end

  CREDIT_FIELDS = {
    "authors" => "author",
    "editors" => "editor",
    "contributors" => "contributor",
    "translators" => "translator",
    "translator" => "translator",
    "compilers" => "compiler",
    "compiler" => "compiler",
    "illustrators" => "illustrator",
    "illustrator" => "illustrator",
    "painters" => "painter",
    "painter" => "painter"
  }.freeze

  def credit_entries(metadata)
    credits = []
    CREDIT_FIELDS.each do |field, default_role|
      values = metadata[field]
      values = [values] unless values.is_a?(Array)
      Array(values).compact.each do |entry|
        if entry.is_a?(Hash)
          name = first_nonblank(entry["name"], entry["name_han"], entry["label"], entry["romanized"])
          roles = split_credit_roles(entry["role"].presence || default_role)
        else
          name = entry.to_s.strip.presence
          roles = [default_role]
        end
        next unless name
        credits << { "name" => name, "roles" => roles }
      end
    end
    credits.group_by { |credit| credit["name"] }.map do |name, rows|
      { "name" => name, "roles" => rows.flat_map { |row| row["roles"] }.uniq }
    end
  end

  def split_credit_roles(value)
    value.to_s.split(/[;；]+/).map(&:strip).reject(&:empty?).presence || ["contributor"]
  end

  def person_name_keys(values)
    Array(values).flat_map do |value|
      text = value.to_s.strip
      next [] if text.empty?

      normalized = text.unicode_normalize(:nfkc).downcase
      latin = normalized.gsub(/\p{Han}+/, " ").gsub(/[^\p{L}\p{N}]+/u, " ").strip
      [*text.scan(/\p{Han}{2,16}/), normalized, latin].reject(&:empty?)
    end.uniq
  end

  def inferred_period_start(metadata, folder)
    labels = [metadata["period"], metadata["polity"], *folder.to_s.split("/").reverse]
      .map(&:to_s).map(&:strip).reject(&:empty?).uniq

    regional = CorpusEntryOrdering::REGIONAL_PERIOD_START.find do |prefix, _values|
      folder.to_s.include?(prefix)
    end&.last
    labels.each { |label| return regional[label] if regional&.key?(label) }
    labels.each { |label| return CorpusEntryOrdering::PERIOD_START[label] if CorpusEntryOrdering::PERIOD_START.key?(label) }
    nil
  end

  def row_preference(row)
    completeness = %w[author date_text corpus_root macro_region period polity region year_start year_end]
      .count { |key| row[key].present? }
    [-completeness, row.fetch("folder_path").length, row.fetch("folder_path")]
  end

  def read_metadata(path)
    raw = path.binread.force_encoding(Encoding::UTF_8)
    return {} unless raw.valid_encoding?

    parsed = JSON.parse(raw.sub(/\A\uFEFF/, ""))
    parsed.is_a?(Hash) ? parsed : {}
  end

  def names_string(value)
    entries = value.is_a?(Array) ? value : [value].compact
    entries.filter_map do |entry|
      if entry.is_a?(Hash)
        first_nonblank(entry["name"], entry["name_han"], entry["label"], entry["romanized"])
      else
        entry.to_s.strip.presence
      end
    end.join("; ").presence
  end

  def create_schema!(db)
    db.execute_batch <<~SQL
      CREATE TABLE metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );

      CREATE TABLE works (
        work_key TEXT PRIMARY KEY,
        work_id TEXT,
        display_title TEXT NOT NULL,
        base_title TEXT NOT NULL,
        folder_path TEXT NOT NULL,
        author TEXT,
        date_text TEXT,
        nation TEXT,
        corpus_root TEXT,
        macro_region TEXT,
        period TEXT,
        polity TEXT,
        region TEXT,
        year_start INTEGER,
        year_end INTEGER,
        sort_year REAL,
        categories_json TEXT
      );

      CREATE TABLE work_people (
        work_key TEXT NOT NULL,
        name_key TEXT NOT NULL,
        display_name TEXT NOT NULL,
        role TEXT NOT NULL,
        PRIMARY KEY (work_key, name_key, display_name, role)
      ) WITHOUT ROWID;

      CREATE TABLE title_keys (
        work_key TEXT NOT NULL,
        title_key TEXT NOT NULL,
        key_kind TEXT NOT NULL,
        PRIMARY KEY (work_key, title_key, key_kind)
      ) WITHOUT ROWID;

      CREATE INDEX catalogue_title_literal ON works(display_title);
      CREATE INDEX catalogue_title_base ON works(base_title);
      CREATE INDEX catalogue_title_keys ON title_keys(title_key, work_key);
      CREATE INDEX catalogue_year ON works(sort_year, year_start, year_end);
      CREATE INDEX catalogue_geography ON works(macro_region, corpus_root, nation);
      CREATE INDEX catalogue_author ON works(author);
      CREATE INDEX catalogue_people ON work_people(name_key, work_key);
    SQL
  end

  def base_title(value)
    text = value.to_s.strip
    pairs = { "《" => "》", "〈" => "〉" }
    closing = pairs[text[0]]
    return text unless closing && text.end_with?(closing)

    text[1...-1].to_s.strip
  end

  def variant_strings(value, limit: 96)
    source = value.to_s.unicode_normalize(:nfkc)
    return [] if source.empty?

    options = source.each_char.map do |character|
      direct = @normaliser.forms_for(character).to_a.reject { |form| form == character }.sort
      [character, *direct]
    end

    output = [source]
    # Always retain one deterministic all-normalised spelling. This means a long
    # traditional title still has a fully simplified/shinjitai search key even
    # when the bounded Cartesian expansion below reaches its limit.
    output << options.map { |forms| forms.min }.join

    options.each_with_index do |forms, index|
      forms.drop(1).each do |replacement|
        chars = source.each_char.to_a
        chars[index] = replacement
        output << chars.join
      end
    end

    partials = [""]
    options.each do |forms|
      next_partials = []
      partials.each do |prefix|
        forms.each do |form|
          next_partials << prefix + form
          break if next_partials.length >= limit
        end
        break if next_partials.length >= limit
      end
      partials = next_partials
    end
    output.concat(partials)
    output.map(&:strip).reject(&:empty?).uniq.first(limit)
  end

  def search_rows(text, order:, geography:, page:, per_page:)
    query_base = base_title(text)
    key_text = text.unicode_normalize(:nfkc)
    key_base = query_base.unicode_normalize(:nfkc)
    literal_prefix = "#{escape_like(text)}%"
    base_prefix = "#{escape_like(query_base)}%"
    literal_contains = "%#{escape_like(text)}%"
    base_contains = "%#{escape_like(query_base)}%"
    key_prefix = "#{escape_like(key_text)}%"
    key_base_prefix = "#{escape_like(key_base)}%"
    key_contains = "%#{escape_like(key_text)}%"
    key_base_contains = "%#{escape_like(key_base)}%"
    offset = (page - 1) * per_page

    sql = <<~SQL
      WITH key_matches AS (
        SELECT work_key, MIN(
          CASE
            WHEN title_key = ? OR title_key = ? THEN 4
            WHEN title_key LIKE ? ESCAPE '\\' OR title_key LIKE ? ESCAPE '\\' THEN 5
            WHEN title_key LIKE ? ESCAPE '\\' OR title_key LIKE ? ESCAPE '\\' THEN 6
            ELSE 99
          END
        ) AS key_rank
        FROM title_keys
        WHERE title_key = ?
           OR title_key = ?
           OR title_key LIKE ? ESCAPE '\\'
           OR title_key LIKE ? ESCAPE '\\'
           OR title_key LIKE ? ESCAPE '\\'
           OR title_key LIKE ? ESCAPE '\\'
        GROUP BY work_key
      ),
      ranked AS (
        SELECT works.*,
          CASE
            WHEN display_title = ? THEN 0
            WHEN base_title = ? THEN 1
            WHEN display_title LIKE ? ESCAPE '\\' OR base_title LIKE ? ESCAPE '\\' THEN 2
            WHEN display_title LIKE ? ESCAPE '\\' OR base_title LIKE ? ESCAPE '\\' THEN 3
            WHEN key_matches.key_rank IS NOT NULL THEN key_matches.key_rank
            ELSE 99
          END AS match_rank
        FROM works
        LEFT JOIN key_matches ON key_matches.work_key = works.work_key
        WHERE display_title = ?
           OR base_title = ?
           OR display_title LIKE ? ESCAPE '\\'
           OR base_title LIKE ? ESCAPE '\\'
           OR display_title LIKE ? ESCAPE '\\'
           OR base_title LIKE ? ESCAPE '\\'
           OR key_matches.work_key IS NOT NULL
      )
      SELECT ranked.*, COUNT(*) OVER() AS total_count
      FROM ranked
      WHERE match_rank < 99
      ORDER BY #{timeline_order(geography: geography, order: order, include_match_rank: true)}
      LIMIT ? OFFSET ?
    SQL

    key_binds = [
      key_text, key_base, key_prefix, key_base_prefix, key_contains, key_base_contains,
      key_text, key_base, key_prefix, key_base_prefix, key_contains, key_base_contains
    ]
    literal_binds = [
      text, query_base, literal_prefix, base_prefix, literal_contains, base_contains,
      text, query_base, literal_prefix, base_prefix, literal_contains, base_contains
    ]
    with_database(readonly: true) { |db| db.execute(sql, [*key_binds, *literal_binds, per_page, offset]) }
  end

  def browse_rows(order:, geography:, page:, per_page:)
    offset = (page - 1) * per_page
    with_database(readonly: true) do |db|
      db.execute(<<~SQL, [per_page, offset])
        SELECT works.*, 0 AS match_rank, COUNT(*) OVER() AS total_count
        FROM works
        ORDER BY #{timeline_order(geography: geography, order: order)}
        LIMIT ? OFFSET ?
      SQL
    end
  end

  def timeline_order(geography:, order:, include_match_rank: false)
    year_direction = order == "desc" ? "DESC" : "ASC"
    parts = []
    if geography
      geography_value = "COALESCE(NULLIF(macro_region, ''), NULLIF(corpus_root, ''), NULLIF(nation, ''), 'Other')"
      parts << <<~SQL.squish
        CASE
          WHEN #{geography_value} IN ('中國', '中國漢文', 'China') OR #{geography_value} LIKE '%中國%' THEN 0
          WHEN #{geography_value} IN ('日本', '日本漢文', 'Japan') OR #{geography_value} LIKE '%日本%' THEN 1
          WHEN #{geography_value} IN ('韓國', '朝鮮', '朝鮮漢文', 'Korea') OR #{geography_value} LIKE '%韓國%' OR #{geography_value} LIKE '%朝鮮%' THEN 2
          WHEN #{geography_value} IN ('越南', '越南漢文', 'Vietnam') OR #{geography_value} LIKE '%越南%' THEN 3
          WHEN #{geography_value} IN ('琉球', '琉球漢文', 'Ryukyu') OR #{geography_value} LIKE '%琉球%' THEN 4
          ELSE 5
        END ASC
      SQL
      parts << "#{geography_value} ASC"
    end
    parts << "CASE WHEN sort_year IS NULL THEN 1 ELSE 0 END ASC"
    parts << "sort_year #{year_direction}"
    parts << "CASE WHEN year_start IS NULL THEN 1 ELSE 0 END ASC"
    parts << "year_start #{year_direction}"
    parts << "CASE WHEN year_end IS NULL THEN 1 ELSE 0 END ASC"
    parts << "year_end #{year_direction}"
    parts << "match_rank ASC" if include_match_rank
    parts << "display_title ASC"
    parts.join(", ")
  end

  def public_row(row)
    data = row.to_h.reject { |key, _| key.is_a?(Integer) }
    data.delete("credit_role")
    data["categories"] = JSON.parse(data.delete("categories_json").to_s)
    data
  rescue JSON::ParserError
    data["categories"] = []
    data
  end

  def with_database(readonly:)
    db = SQLite3::Database.new(@path.to_s, readonly: readonly)
    db.results_as_hash = true
    yield db
  ensure
    db&.close
  end

  def integer_parameter(value, default:)
    text = value.to_s.strip
    return default if text.empty?

    Integer(text, 10)
  rescue ArgumentError, TypeError
    default
  end

  def integer_or_nil(value)
    return value.to_i if value.is_a?(Numeric)
    text = value.to_s.strip
    text.match?(/\A-?\d+\z/) ? text.to_i : nil
  end

  def first_nonblank(*values)
    values.each do |value|
      text = value.to_s.strip
      return text unless text.empty?
    end
    nil
  end

  def escape_like(value)
    value.to_s.gsub(/[\\%_]/) { |character| "\\#{character}" }
  end

  def missing_message
    "The work catalogue has not been built. Run bin/rails corpus_catalogue:rebuild."
  end
end
