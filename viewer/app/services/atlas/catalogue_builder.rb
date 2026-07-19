# frozen_string_literal: true

require "json"
require "pathname"
require "set"
require "time"

module Atlas
  # Compiles source atlas metadata and the corpus manifest into one small runtime
  # catalogue. This runs during maintenance, never during a web request.
  class CatalogueBuilder
    VERSION = Catalogue::VERSION
    CACHE_PATH = Catalogue::CACHE_PATH
    SOURCE_ROOT = Rails.root.join("content", "atlas")

    Result = Struct.new(
      :entry_count, :macro_region_count, :period_count, :document_count,
      :work_count, :path, :source,
      keyword_init: true
    )

    def self.build!(manifest:, cache_store: CorpusSearch::CacheStore.new, source_root: SOURCE_ROOT, periodisation: Periodisation.default)
      new(cache_store: cache_store, source_root: source_root, periodisation: periodisation)
        .build!(manifest: manifest)
    end

    def initialize(cache_store: CorpusSearch::CacheStore.new, source_root: SOURCE_ROOT, periodisation: Periodisation.default)
      @cache_store = cache_store
      @source_root = Pathname.new(source_root)
      @periodisation = periodisation
    end

    def build!(manifest:)
      documents = searchable_documents(Array(manifest.documents))
      payload = compile(
        documents: documents,
        generated_at: Time.now.utc.iso8601,
        manifest_generated_at: manifest.generated_at.to_s,
        source: "corpus_manifest"
      )
      path = @cache_store.write_json(CACHE_PATH, payload)
      result_for(payload, path: path, source: "corpus_manifest")
    end

    private

    def compile(documents:, generated_at:, manifest_generated_at:, source:)
      source_entries = load_source_entries
      documents_by_key = index_documents(documents)
      entry_rows = source_entries.map do |payload|
        enrich_entry(payload, documents_by_key: documents_by_key)
      end

      macro_regions = build_macro_regions(entry_rows, documents)
      aliases = build_aliases(entry_rows)
      indexes = build_indexes(entry_rows, macro_regions)

      payload = {
        "version" => VERSION,
        "generated_at" => generated_at,
        "manifest_generated_at" => manifest_generated_at,
        "source" => source,
        "entries" => entry_rows.sort_by { |row| [row.dig("name", "display").to_s, row.fetch("id")] },
        "macro_regions" => macro_regions,
        "aliases" => aliases,
        "indexes" => indexes,
        "totals" => {
          "entries" => entry_rows.length,
          "macro_regions" => macro_regions.length,
          "periods" => macro_regions.sum { |row| Array(row["periods"]).length },
          "documents" => documents.length,
          "works" => distinct_work_ids(documents).length
        }
      }

      validate_compiled_payload!(payload)
      payload
    end

    def load_source_entries
      paths = Dir.glob(@source_root.join("entries", "**", "metadata.json").to_s).sort
      raise ArgumentError, "No atlas entry metadata was found under #{@source_root.join("entries")}" if paths.empty?

      rows = paths.map do |filename|
        metadata_path = Pathname.new(filename)
        raw = metadata_path.binread.force_encoding(Encoding::UTF_8)
        raise ArgumentError, "Atlas metadata is not valid UTF-8: #{metadata_path}" unless raw.valid_encoding?

        payload = JSON.parse(raw)
        raise ArgumentError, "Atlas metadata must be a mapping: #{metadata_path}" unless payload.is_a?(Hash)

        row = Grammar::MarkdownDocument.stringify_keys(payload)
        row["source_metadata_path"] = metadata_path.relative_path_from(@source_root).to_s.tr("\\", "/")

        # Use the path that actually exists in this tree. This avoids trusting an
        # old path field that may have been damaged by a ZIP filename conversion.
        article_path = metadata_path.dirname.join("index.md").relative_path_from(@source_root).to_s.tr("\\", "/")
        row["article_path"] = article_path
        row["published"] = @source_root.join(article_path).file?
        row
      rescue JSON::ParserError => e
        raise ArgumentError, "Invalid atlas metadata JSON in #{metadata_path}: #{e.message}"
      end

      ids = rows.map { |row| row.fetch("id").to_s }
      duplicate_ids = ids.group_by(&:itself).select { |_id, values| values.length > 1 }.keys
      raise ArgumentError, "Duplicate atlas IDs: #{duplicate_ids.join(', ')}" if duplicate_ids.any?

      Atlas::UnicodeGuard.validate!(rows, context: "atlas source metadata")
      rows
    end

    def searchable_documents(documents)
      documents.select do |document|
        role = document["document_role"].presence || CorpusSearch::DocumentRole.classify(document["path"])
        CorpusSearch::DocumentRole.searchable?(role) && document["searchable_body"] != false
      end
    end

    def index_documents(documents)
      documents.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |document, index|
        root = document["corpus_root"].to_s.strip
        polity = document["polity"].to_s.strip
        next if root.empty? || polity.empty?

        index[[root, polity]] << document
      end
    end

    def enrich_entry(source, documents_by_key:)
      row = deep_dup(source)
      source_atlas = Grammar::MarkdownDocument.stringify_keys(row["atlas"].to_h)
      corpus = Grammar::MarkdownDocument.stringify_keys(row["corpus"].to_h)
      root = corpus["root"].to_s
      periods = Array(corpus["periods"]).map(&:to_s).reject(&:blank?).uniq
      polity = corpus["polity"].to_s

      documents = Array(documents_by_key[[root, polity]])
      paths = Array(corpus["paths"]).map(&:to_s).reject(&:blank?)
      if paths.any?
        documents = documents.select do |document|
          document_path = document["path"].to_s
          folder_path = document["folder_path"].to_s
          paths.any? do |path|
            document_path == path || document_path.start_with?(path + "/") ||
              folder_path == path || folder_path.start_with?(path + "/")
          end
        end
      end
      documents = documents.uniq { |document| document["id"].to_s }

      macro_regions = documents.filter_map do |document|
        @periodisation.normalise_macro_region(
          document["macro_region"],
          corpus_root: document["corpus_root"]
        ).presence
      end.uniq
      fallback_region = @periodisation.macro_region_for_root(root)
      macro_regions << fallback_region if macro_regions.empty? && fallback_region.present?
      derived_periods = documents.filter_map { |document| document["period"].to_s.presence }.uniq
      derived_periods = Array(source_atlas["periods"]).map(&:to_s).reject(&:blank?).uniq if derived_periods.empty?
      derived_periods = periods if derived_periods.empty?
      if derived_periods.empty? && @periodisation.macro_region(fallback_region)
        configured = Array(@periodisation.macro_region(fallback_region)["periods"])
        derived_periods = [polity] if configured.include?(polity)
      end

      corpus["root"] = root
      corpus["periods"] = periods
      corpus["polity"] = polity
      row["corpus"] = corpus
      row["atlas"] = {
        "macro_regions" => macro_regions.compact.uniq,
        "periods" => derived_periods,
        "corpus_stats" => corpus_stats(documents)
      }
      row
    end

    def corpus_stats(documents)
      work_groups = documents.group_by { |document| work_identity(document) }
      author_groups = documents.reject { |document| document["author"].to_s.blank? }.group_by { |document| document["author"].to_s }

      represented_authors = author_groups.map do |name, rows|
        {
          "name" => name,
          "work_count" => distinct_work_ids(rows).length,
          "document_count" => rows.length
        }
      end.sort_by { |row| [-row["work_count"], -row["document_count"], row["name"]] }.first(12)

      represented_works = work_groups.map do |work_id, rows|
        first = rows.first
        title = first["work"].to_s.presence || first["title"].to_s.presence || File.basename(first["folder_path"].to_s)
        {
          "id" => work_id,
          "title" => title,
          "document_count" => rows.length,
          "path" => first["path"].to_s
        }
      end.reject { |row| row["title"].blank? }
        .sort_by { |row| [-row["document_count"], row["title"]] }
        .first(12)

      {
        "document_count" => documents.length,
        "work_count" => work_groups.length,
        "searchable_characters" => documents.sum { |document| document["searchable_characters"].to_i },
        "represented_authors" => represented_authors,
        "represented_works" => represented_works
      }
    end

    def build_macro_regions(entry_rows, documents)
      document_stats = aggregate_document_stats(documents)
      entries_by_region_period = Hash.new { |hash, key| hash[key] = [] }
      entries_by_region = Hash.new { |hash, key| hash[key] = [] }

      entry_rows.each do |row|
        entry_id = row.fetch("id").to_s
        regions = Array(row.dig("atlas", "macro_regions")).map(&:to_s).reject(&:blank?)
        periods = Array(row.dig("atlas", "periods")).map(&:to_s).reject(&:blank?)
        regions.each do |region|
          entries_by_region[region] << entry_id
          periods.each { |period| entries_by_region_period[[region, period]] << entry_id }
        end
      end

      configured_regions = @periodisation.macro_regions.map { |row| row.fetch("id") }
      discovered_regions = (configured_regions + entries_by_region.keys + document_stats.fetch(:regions).keys).uniq
      ordered_regions = discovered_regions.sort_by do |region|
        [@periodisation.macro_region_order(region), @periodisation.label_for(region)]
      end

      ordered_regions.map do |region|
        discovered_periods = entries_by_region_period.keys.filter_map { |key_region, period| period if key_region == region }
        discovered_periods.concat(document_stats.fetch(:periods).keys.filter_map { |key_region, period| period if key_region == region })
        periods = discovered_periods.uniq.sort_by do |period|
          [@periodisation.period_order(region, period), period]
        end

        period_rows = periods.map do |period|
          ids = entries_by_region_period[[region, period]].uniq
          stats = document_stats.fetch(:periods)[[region, period]] || empty_stats
          {
            "id" => period,
            "label" => period,
            "entry_ids" => ids.sort_by { |id| entry_title(entry_rows, id) },
            "polity_count" => ids.length,
            "document_count" => stats.fetch("document_count"),
            "work_count" => stats.fetch("work_count")
          }
        end

        stats = document_stats.fetch(:regions)[region] || empty_stats
        ids = entries_by_region[region].uniq
        config = @periodisation.macro_region(region) || {}
        {
          "id" => region,
          "label" => config["label"].presence || region,
          "corpus_roots" => Array(config["corpus_roots"]).map(&:to_s),
          "entry_ids" => ids.sort_by { |id| entry_title(entry_rows, id) },
          "polity_count" => ids.length,
          "period_count" => period_rows.length,
          "document_count" => stats.fetch("document_count"),
          "work_count" => stats.fetch("work_count"),
          "periods" => period_rows
        }
      end
    end

    def aggregate_document_stats(documents)
      region_rows = Hash.new { |hash, key| hash[key] = [] }
      period_rows = Hash.new { |hash, key| hash[key] = [] }

      documents.each do |document|
        region = @periodisation.normalise_macro_region(
          document["macro_region"],
          corpus_root: document["corpus_root"]
        ).presence
        period = document["period"].to_s
        next if region.blank?

        region_rows[region] << document
        period_rows[[region, period]] << document if period.present?
      end

      {
        regions: region_rows.transform_values { |rows| count_stats(rows) },
        periods: period_rows.transform_values { |rows| count_stats(rows) }
      }
    end

    def count_stats(documents)
      {
        "document_count" => documents.length,
        "work_count" => distinct_work_ids(documents).length
      }
    end

    def empty_stats
      { "document_count" => 0, "work_count" => 0 }
    end

    def build_aliases(entry_rows)
      # Existing IDs remain canonical for now. This mapping exists so later ASCII
      # migrations can preserve old URLs without changing the controller contract.
      entry_rows.each_with_object({}) do |row, aliases|
        Array(row["legacy_ids"]).each { |legacy| aliases[legacy.to_s] = row.fetch("id").to_s }
      end
    end

    def build_indexes(entry_rows, macro_regions)
      entry_by_corpus_key = {}
      entry_rows.each do |row|
        root = row.dig("corpus", "root").to_s
        polity = row.dig("corpus", "polity").to_s
        Array(row.dig("corpus", "periods")).each do |period|
          key = [root, period, polity].map(&:to_s).join("\u0000")
          entry_by_corpus_key[key] = row.fetch("id").to_s
        end
      end

      macro_region_by_corpus_root = {}
      macro_regions.each do |region|
        Array(region["corpus_roots"]).each do |root|
          macro_region_by_corpus_root[root.to_s] = region.fetch("id").to_s
        end
      end

      {
        "entry_by_corpus_key" => entry_by_corpus_key,
        "macro_region_by_corpus_root" => macro_region_by_corpus_root
      }
    end

    def validate_compiled_payload!(payload)
      ids = payload.fetch("entries").map { |row| row.fetch("id").to_s }
      duplicates = ids.group_by(&:itself).select { |_id, rows| rows.length > 1 }.keys
      raise ArgumentError, "Duplicate atlas IDs: #{duplicates.join(', ')}" if duplicates.any?

      payload.fetch("entries").each do |row|
        unknown = Array(row["related"]).map(&:to_s) - ids
        raise ArgumentError, "Unknown atlas links for #{row['id']}: #{unknown.join(', ')}" if unknown.any?
      end

      Atlas::UnicodeGuard.validate!(payload, context: "compiled atlas catalogue")
      true
    end

    def result_for(payload, path:, source:)
      totals = payload.fetch("totals")
      Result.new(
        entry_count: totals.fetch("entries"),
        macro_region_count: totals.fetch("macro_regions"),
        period_count: totals.fetch("periods"),
        document_count: totals.fetch("documents"),
        work_count: totals.fetch("works"),
        path: Pathname.new(path),
        source: source
      )
    end

    def distinct_work_ids(documents)
      documents.map { |document| work_identity(document) }.reject(&:blank?).uniq
    end

    def work_identity(document)
      document["work_id"].to_s.presence || document["folder_path"].to_s.presence || document["path"].to_s
    end

    def entry_title(entry_rows, id)
      row = entry_rows.find { |candidate| candidate["id"].to_s == id.to_s }
      row&.dig("name", "display").to_s.presence || id.to_s
    end

    def deep_dup(value)
      Marshal.load(Marshal.dump(value))
    end

  end
end
