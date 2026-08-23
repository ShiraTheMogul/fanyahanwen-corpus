# frozen_string_literal: true

require "json"
require "sqlite3"
require "fileutils"
require "securerandom"
require "time"

module CorpusSearch
  # Work-level title catalogue built during corpus-search maintenance.
  #
  # The web request never walks the corpus and never loads the full manifest.
  # One small SQLite cache contains one row per work plus its known title forms.
  # Stored/displayed titles are preserved exactly; normalised forms exist only
  # as derived search keys.
  class TitleIndex
    VERSION = 1
    DB_PATH = "title-index-v1.sqlite3"
    DEFAULT_LIMIT = 250
    MAX_LIMIT = 1_000

    class CacheMissing < StandardError; end

    attr_reader :manifest_generated_at, :equivalence_version, :work_count

    def self.load(cache_store: CacheStore.new)
      new(cache_store: cache_store).tap(&:load!)
    end

    def self.build!(manifest:, cache_store: CacheStore.new)
      new(cache_store: cache_store).build!(manifest)
    end

    def initialize(cache_store: CacheStore.new)
      @cache_store = cache_store
      @path = cache_store.absolute(DB_PATH)
      @manifest_generated_at = ""
      @equivalence_version = ""
      @work_count = 0
    end

    def load!
      raise CacheMissing, missing_message unless @path.file?

      with_database(readonly: true) do |db|
        metadata = db.execute("SELECT key, value FROM metadata").to_h { |row| [row["key"], row["value"]] }
        raise CacheMissing, missing_message unless metadata["version"].to_i == VERSION

        @manifest_generated_at = metadata["manifest_generated_at"].to_s
        @equivalence_version = metadata["equivalence_version"].to_s
        @work_count = metadata["work_count"].to_i
      end
      self
    rescue SQLite3::Exception
      raise CacheMissing, missing_message
    end

    def current_for?(manifest_generated_at:)
      load! unless @work_count.positive?
      @manifest_generated_at == manifest_generated_at.to_s &&
        @equivalence_version == CharacterEquivalenceRegistry.version_for("broad")
    rescue CacheMissing
      false
    end

    def build!(manifest)
      FileUtils.mkdir_p(@path.dirname)
      temporary = @path.dirname.join(".#{@path.basename}.#{$$}.#{SecureRandom.hex(6)}.tmp")
      FileUtils.rm_f(temporary)

      registry = CharacterEquivalenceRegistry.new(level: "broad")
      groups = work_groups(Array(manifest.documents))

      db = SQLite3::Database.new(temporary.to_s)
      db.results_as_hash = true
      db.execute("PRAGMA journal_mode = OFF")
      db.execute("PRAGMA synchronous = OFF")
      create_schema!(db)

      insert_work = db.prepare(<<~SQL)
        INSERT INTO works (
          work_key, work_id, display_title, base_title, folder_path,
          author, date_text, nation, corpus_root, macro_region, period,
          polity, region, year_start, year_end, categories_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      insert_form = db.prepare(<<~SQL)
        INSERT OR IGNORE INTO title_forms (
          work_key, form, normalised_form, form_kind
        ) VALUES (?, ?, ?, ?)
      SQL

      db.transaction do
        groups.each_value do |documents|
          row = build_work_row(documents)
          next unless row

          insert_work.execute(
            row.fetch("work_key"), row["work_id"], row.fetch("display_title"),
            row.fetch("base_title"), row.fetch("folder_path"), row["author"],
            row["date_text"], row["nation"], row["corpus_root"], row["macro_region"],
            row["period"], row["polity"], row["region"], row["year_start"],
            row["year_end"], JSON.generate(row["categories"])
          )

          forms_for_work(documents, row).each do |form, kind|
            insert_form.execute(
              row.fetch("work_key"),
              form,
              normalise(form, registry),
              kind
            )
          end
        end

        metadata = {
          "version" => VERSION.to_s,
          "manifest_generated_at" => manifest.generated_at.to_s,
          "equivalence_version" => registry.version.to_s,
          "work_count" => groups.length.to_s,
          "generated_at" => Time.now.utc.iso8601
        }
        metadata.each do |key, value|
          db.execute("INSERT INTO metadata (key, value) VALUES (?, ?)", [key, value])
        end
      end

      insert_form.close
      insert_work.close
      db.execute("ANALYZE")
      db.close
      FileUtils.mv(temporary, @path)
      load!
    ensure
      db&.close rescue nil
      FileUtils.rm_f(temporary) if defined?(temporary) && temporary
    end

    def search(query:, group_geography: true, chronology: "asc", limit: DEFAULT_LIMIT)
      load! if @work_count.zero?
      text = query.to_s.strip
      return [] if text.empty?

      chosen_limit = [[Integer(limit), 1].max, MAX_LIMIT].min
      order = chronology.to_s == "desc" ? "desc" : "asc"
      registry = CharacterEquivalenceRegistry.new(level: "broad")
      normalised = normalise(text, registry)
      literal_prefix = "#{escape_like(text)}%"
      literal_contains = "%#{escape_like(text)}%"
      normal_prefix = "#{escape_like(normalised)}%"
      normal_contains = "%#{escape_like(normalised)}%"

      sql = <<~SQL
        WITH ranked AS (
          SELECT
            f.work_key,
            f.form AS matched_form,
            f.form_kind,
            CASE
              WHEN f.form = ? AND f.form_kind = 'title' THEN 0
              WHEN f.form = ? AND f.form_kind = 'base' THEN 1
              WHEN f.form LIKE ? ESCAPE '\' AND f.form_kind = 'title' THEN 2
              WHEN f.form LIKE ? ESCAPE '\' AND f.form_kind <> 'title' THEN 2
              WHEN f.form LIKE ? ESCAPE '\' AND f.form_kind = 'title' THEN 3
              WHEN f.form LIKE ? ESCAPE '\' AND f.form_kind <> 'title' THEN 3
              WHEN f.normalised_form = ? AND f.form_kind = 'title' THEN 4
              WHEN f.normalised_form = ? AND f.form_kind <> 'title' THEN 4
              WHEN f.normalised_form LIKE ? ESCAPE '\' AND f.form_kind = 'title' THEN 5
              WHEN f.normalised_form LIKE ? ESCAPE '\' AND f.form_kind <> 'title' THEN 5
              WHEN f.normalised_form LIKE ? ESCAPE '\' AND f.form_kind = 'title' THEN 6
              WHEN f.normalised_form LIKE ? ESCAPE '\' AND f.form_kind <> 'title' THEN 6
              ELSE 99
            END AS match_rank
          FROM title_forms f
          WHERE
            f.form = ?
            OR f.form LIKE ? ESCAPE '\'
            OR f.form LIKE ? ESCAPE '\'
            OR f.normalised_form = ?
            OR f.normalised_form LIKE ? ESCAPE '\'
            OR f.normalised_form LIKE ? ESCAPE '\'
        ),
        best AS (
          SELECT work_key, MIN(match_rank) AS match_rank
          FROM ranked
          WHERE match_rank < 99
          GROUP BY work_key
        )
        SELECT
          w.*,
          best.match_rank,
          (
            SELECT r.matched_form
            FROM ranked r
            WHERE r.work_key = w.work_key AND r.match_rank = best.match_rank
            ORDER BY CASE r.form_kind WHEN 'title' THEN 0 WHEN 'base' THEN 1 ELSE 2 END,
                     length(r.matched_form), r.matched_form
            LIMIT 1
          ) AS matched_form
        FROM best
        JOIN works w ON w.work_key = best.work_key
        ORDER BY __TITLE_ORDER__
        LIMIT ?
      SQL

      binds = [
        text, text,
        literal_prefix, literal_prefix,
        literal_contains, literal_contains,
        normalised, normalised,
        normal_prefix, normal_prefix,
        normal_contains, normal_contains,
        text, literal_prefix, literal_contains,
        normalised, normal_prefix, normal_contains,
        chosen_limit
      ]

      rows = with_database(readonly: true) do |db|
        db.execute(sql.sub("__TITLE_ORDER__", sql_order(group_geography: group_geography, chronology: order)), binds)
      end

      rows.map { |row| public_row(row) }
    rescue ArgumentError, TypeError
      []
    end

    private

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
          categories_json TEXT
        );

        CREATE TABLE title_forms (
          work_key TEXT NOT NULL,
          form TEXT NOT NULL,
          normalised_form TEXT NOT NULL,
          form_kind TEXT NOT NULL,
          PRIMARY KEY (work_key, form, form_kind)
        );

        CREATE INDEX idx_title_forms_form ON title_forms(form);
        CREATE INDEX idx_title_forms_normalised ON title_forms(normalised_form);
        CREATE INDEX idx_works_year_start ON works(year_start);
        CREATE INDEX idx_works_macro_region ON works(macro_region);
        CREATE INDEX idx_works_corpus_root ON works(corpus_root);
      SQL
    end

    def work_groups(documents)
      groups = Hash.new { |hash, key| hash[key] = [] }
      documents.each do |document|
        role = document["document_role"].presence || DocumentRole.classify(document["path"])
        next unless DocumentRole.default?(role)
        next if document["path"].to_s.split("/").any? { |segment| segment.casecmp("normalisations").zero? || segment.casecmp("normalizations").zero? }

        work_id = document["work_id"].to_s.strip
        folder = document["canonical_parent_path"].presence || document["folder_path"].presence || DocumentRole.folder_path(document["path"])
        key = work_id.present? ? "work:#{work_id}" : "folder:#{folder}"
        groups[key] << document
      end
      groups
    end

    def build_work_row(documents)
      representative = documents.min_by { |document| representative_rank(document) }
      return nil unless representative

      work_id = representative["work_id"].to_s.strip.presence
      folder = representative["canonical_parent_path"].presence ||
        representative["folder_path"].presence ||
        DocumentRole.folder_path(representative["path"])

      work_values = documents.map { |document| document["work"].to_s.strip }.reject(&:empty?)
      title_values = documents.map { |document| document["title"].to_s.strip }.reject(&:empty?)
      display_title = representative["title"].to_s.strip.presence || title_values.first
      base_title = representative["work"].to_s.strip.presence || work_values.first || display_title
      display_title ||= base_title || File.basename(folder.to_s)
      base_title ||= display_title

      {
        "work_key" => work_id ? "work:#{work_id}" : "folder:#{folder}",
        "work_id" => work_id,
        "display_title" => display_title,
        "base_title" => base_title,
        "folder_path" => folder,
        "author" => first_present(documents, "author"),
        "date_text" => first_present(documents, "date_text"),
        "nation" => first_present(documents, "nation"),
        "corpus_root" => first_present(documents, "corpus_root"),
        "macro_region" => first_present(documents, "macro_region"),
        "period" => first_present(documents, "period"),
        "polity" => first_present(documents, "polity"),
        "region" => first_present(documents, "region"),
        "year_start" => first_integer(documents, "year_start"),
        "year_end" => first_integer(documents, "year_end"),
        "categories" => documents.flat_map { |document| Array(document["categories"]) }
          .map(&:to_s).map(&:strip).reject(&:empty?).uniq
      }
    end

    def forms_for_work(documents, row)
      forms = []
      documents.each do |document|
        title = document["title"].to_s.strip
        work = document["work"].to_s.strip
        forms << [title, "title"] unless title.empty?
        forms << [work, "base"] unless work.empty?
      end
      forms << [row.fetch("display_title"), "title"]
      forms << [row.fetch("base_title"), "base"]
      forms.uniq
    end

    def representative_rank(document)
      role = document["document_role"].presence || DocumentRole.classify(document["path"])
      role_rank = {
        "canonical" => 0,
        "textual_variant" => 1,
        "reconstruction" => 2,
        "derived_reading" => 3,
        "translation" => 4,
        "annotation" => 5,
        "raw" => 6
      }.fetch(role, 9)
      [role_rank, document["path"].to_s]
    end

    def first_present(documents, field)
      documents.lazy.map { |document| document[field].to_s.strip }.find(&:present?)
    end

    def first_integer(documents, field)
      documents.each do |document|
        value = document[field]
        return value.to_i if value.to_s.match?(/\A-?\d+\z/)
      end
      nil
    end

    def normalise(value, registry)
      value.to_s.each_char.map do |character|
        next character unless character.match?(/\p{Han}/)

        registry.forms_for(character).to_a.min || character
      end.join
    rescue StandardError
      value.to_s
    end

    def escape_like(value)
      value.to_s.gsub(/[\\%_]/) { |character| "\\#{character}" }
    end

    def public_row(row)
      {
        "work_key" => row["work_key"],
        "work_id" => row["work_id"].presence,
        "title" => row["display_title"],
        "base_title" => row["base_title"],
        "folder_path" => row["folder_path"],
        "matched_form" => row["matched_form"],
        "match_rank" => row["match_rank"].to_i,
        "match_kind" => match_kind(row["match_rank"].to_i),
        "author" => row["author"].presence,
        "date_text" => row["date_text"].presence,
        "nation" => row["nation"].presence,
        "corpus_root" => row["corpus_root"].presence,
        "macro_region" => row["macro_region"].presence,
        "period" => row["period"].presence,
        "polity" => row["polity"].presence,
        "region" => row["region"].presence,
        "year_start" => row["year_start"],
        "year_end" => row["year_end"],
        "categories" => parse_array(row["categories_json"])
      }.compact
    end

    def match_kind(rank)
      case rank
      when 0 then "exact_title"
      when 1 then "exact_base_title"
      when 2 then "prefix"
      when 3 then "contains"
      else "variant_normalised"
      end
    end

    def sql_order(group_geography:, chronology:)
      geography = "COALESCE(NULLIF(w.macro_region, ''), NULLIF(w.nation, ''), NULLIF(w.corpus_root, ''), '')"
      geography_rank = <<~SQL.squish
        CASE #{geography}
          WHEN '中國' THEN 0
          WHEN 'China' THEN 0
          WHEN '中國漢文' THEN 0
          WHEN '日本' THEN 1
          WHEN 'Japan' THEN 1
          WHEN '日本漢文' THEN 1
          WHEN '韓國' THEN 2
          WHEN '朝鮮' THEN 2
          WHEN 'Korea' THEN 2
          WHEN '韓國漢文' THEN 2
          WHEN '越南' THEN 3
          WHEN 'Vietnam' THEN 3
          WHEN '越南漢文' THEN 3
          WHEN '琉球' THEN 4
          WHEN 'Ryukyu' THEN 4
          WHEN '琉球漢文' THEN 4
          ELSE 50
        END
      SQL
      year_direction = chronology == "desc" ? "DESC" : "ASC"
      parts = []
      parts << geography_rank << geography if group_geography
      parts << "CASE WHEN w.year_start IS NULL THEN 1 ELSE 0 END"
      parts << "w.year_start #{year_direction}"
      parts << "best.match_rank"
      parts << "w.display_title"
      parts.join(", ")
    end

    def parse_array(value)
      parsed = JSON.parse(value.to_s)
      parsed.is_a?(Array) ? parsed : []
    rescue JSON::ParserError
      []
    end

    def with_database(readonly:)
      flags = readonly ? SQLite3::Constants::Open::READONLY : (SQLite3::Constants::Open::READWRITE | SQLite3::Constants::Open::CREATE)
      db = SQLite3::Database.new(@path.to_s, flags: flags)
      db.results_as_hash = true
      yield db
    ensure
      db&.close
    end

    def missing_message
      "The work-title index has not been built. Run bin/rails corpus_search:rebuild_manifest or bin/rails corpus_search:rebuild_title_index."
    end
  end
end
