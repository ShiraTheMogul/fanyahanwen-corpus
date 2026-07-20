# frozen_string_literal: true

require "json"
require "pathname"
require "set"
require "time"

module Atlas
  # Compiles polity sources, typed period sources, and the corpus manifest into
  # one compact runtime catalogue. No corpus or source-tree traversal occurs in
  # a web request.
  class CatalogueBuilder
    VERSION = Catalogue::VERSION
    CACHE_PATH = Catalogue::CACHE_PATH
    SOURCE_ROOT = Rails.root.join("content", "atlas")

    Result = Struct.new(
      :entry_count, :macro_region_count, :period_count, :document_count,
      :work_count, :path, :source,
      keyword_init: true
    )

    def self.build!(manifest:, directory_index: nil, cache_store: CorpusSearch::CacheStore.new, source_root: SOURCE_ROOT, periodisation: Periodisation.default)
      new(cache_store: cache_store, source_root: source_root, periodisation: periodisation)
        .build!(manifest: manifest, directory_index: directory_index)
    end

    def initialize(cache_store: CorpusSearch::CacheStore.new, source_root: SOURCE_ROOT, periodisation: Periodisation.default)
      @cache_store = cache_store
      @source_root = Pathname.new(source_root)
      @periodisation = periodisation
    end

    def build!(manifest:, directory_index: nil)
      @periodisation.validate!
      documents = searchable_documents(Array(manifest.documents))
        .reject { |document| @periodisation.excluded_corpus_root?(document["corpus_root"]) }
      directory_paths = Array(directory_index&.paths).reject do |path|
        @periodisation.excluded_corpus_root?(path.to_s.split("/").first)
      end
      payload = compile(
        documents: documents,
        directory_paths: directory_paths,
        generated_at: Time.now.utc.iso8601,
        manifest_generated_at: manifest.generated_at.to_s,
        source: "corpus_manifest"
      )
      path = @cache_store.write_json(CACHE_PATH, payload)
      result_for(payload, path: path, source: "corpus_manifest")
    end

    private

    def compile(documents:, directory_paths:, generated_at:, manifest_generated_at:, source:)
      source_entries = load_source_entries
      discovery = Atlas::PolityDiscovery.new(periodisation: @periodisation).merge(
        source_entries: source_entries,
        documents: documents,
        directory_paths: directory_paths
      )
      documents_by_key = index_documents(documents)
      documents_by_root = documents.group_by { |document| document["corpus_root"].to_s }
      entry_rows = discovery.entries.map do |payload|
        enrich_entry(
          payload,
          documents_by_key: documents_by_key,
          documents_by_root: documents_by_root
        )
      end
      entry_rows.select! do |row|
        Array(row.dig("atlas", "macro_regions")).any?
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
          "periods" => macro_regions.sum { |row| count_compiled_periods(row["periods"]) },
          "documents" => documents.length,
          "works" => distinct_work_ids(documents).length
        }
      }

      validate_compiled_payload!(payload)
      payload
    end

    def load_source_entries
      paths = Dir.glob(@source_root.join("entries", "*", "metadata.json").to_s).sort
      raise ArgumentError, "No atlas polity metadata was found under #{@source_root.join('entries')}" if paths.empty?

      rows = paths.map do |filename|
        metadata_path = Pathname.new(filename)
        raw = metadata_path.binread.force_encoding(Encoding::UTF_8)
        raise ArgumentError, "Atlas metadata is not valid UTF-8: #{metadata_path}" unless raw.valid_encoding?

        payload = JSON.parse(raw)
        raise ArgumentError, "Atlas metadata must be a mapping: #{metadata_path}" unless payload.is_a?(Hash)

        row = Grammar::MarkdownDocument.stringify_keys(payload)
        kind = row.fetch("kind", "polity").to_s
        unless kind == "polity"
          raise ArgumentError, "Only polities belong under content/atlas/entries: #{metadata_path} is #{kind.inspect}"
        end

        row["source_metadata_path"] = metadata_path.relative_path_from(@source_root).to_s.tr("\\", "/")
        article_path = metadata_path.dirname.join("index.md").relative_path_from(@source_root).to_s.tr("\\", "/")
        row["article_path"] = article_path
        row["published"] = @source_root.join(article_path).file?
        sanitise_public_aliases!(row)
        row
      rescue JSON::ParserError => error
        raise ArgumentError, "Invalid atlas metadata JSON in #{metadata_path}: #{error.message}"
      end

      ids = rows.map { |row| row.fetch("id").to_s }
      duplicate_ids = ids.group_by(&:itself).select { |_id, values| values.length > 1 }.keys
      raise ArgumentError, "Duplicate atlas IDs: #{duplicate_ids.join(', ')}" if duplicate_ids.any?

      Atlas::UnicodeGuard.validate!(rows, context: "atlas polity source metadata")
      rows
    end

    def sanitise_public_aliases!(row)
      name = Grammar::MarkdownDocument.stringify_keys(row["name"].to_h)
      corpus = Grammar::MarkdownDocument.stringify_keys(row["corpus"].to_h)
      blocked = Set.new
      blocked.merge(Array(corpus["periods"]).map(&:to_s))
      blocked.merge(@periodisation.periods.flat_map do |period|
        [period["id"], period["label"], *Array(period["manifest_periods"])]
      end.map(&:to_s))
      blocked.merge(@periodisation.macro_regions.flat_map do |region|
        [region["id"], region["label"], *Array(region["corpus_roots"])]
      end.map(&:to_s))
      blocked << name["display"].to_s
      blocked << name["hanzi"].to_s

      name["alt"] = Array(name["alt"]).map(&:to_s).reject(&:blank?).reject do |value|
        blocked.include?(value) || value.include?("--") || value.include?("/") || value.include?("\\")
      end.uniq
      row["name"] = name
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

    def enrich_entry(source, documents_by_key:, documents_by_root:)
      row = deep_dup(source)
      source_atlas = Grammar::MarkdownDocument.stringify_keys(row["atlas"].to_h)
      corpus = Grammar::MarkdownDocument.stringify_keys(row["corpus"].to_h)
      root = corpus["root"].to_s
      corpus_periods = Array(corpus["periods"]).map(&:to_s).reject(&:blank?).uniq
      polity = corpus["polity"].to_s
      paths = Array(corpus["paths"]).map(&:to_s).reject(&:blank?).uniq

      keyed_documents = Array(documents_by_key[[root, polity]])
      path_documents = if paths.any?
                         Array(documents_by_root[root]).select do |document|
                           document_path = document["path"].to_s
                           folder_path = document["folder_path"].to_s
                           paths.any? do |path|
                             path_within?(document_path, path) || path_within?(folder_path, path)
                           end
                         end
                       else
                         []
                       end
      documents = (keyed_documents + path_documents).uniq { |document| document["id"].to_s.presence || [document["path"], document["folder_path"]] }

      macro_regions = documents.filter_map do |document|
        @periodisation.normalise_macro_region(
          document["macro_region"],
          corpus_root: document["corpus_root"]
        ).presence
      end.uniq
      fallback_region = @periodisation.macro_region_for_root(root)
      macro_regions << fallback_region if macro_regions.empty? && fallback_region.present?

      manifest_periods = documents.filter_map { |document| document["period"].to_s.presence }
      manifest_periods.concat(corpus_periods)
      explicit_period_ids = Array(source_atlas["period_ids"]).map(&:to_s).reject(&:blank?)
      period_ids_by_region = @periodisation.period_ids_for_entry(
        root: root,
        paths: paths,
        manifest_periods: manifest_periods.uniq,
        explicit_ids: explicit_period_ids,
        macro_regions: macro_regions
      )

      corpus["root"] = root
      corpus["periods"] = corpus_periods
      corpus["polity"] = polity
      corpus["paths"] = paths
      row["corpus"] = corpus
      row["atlas"] = source_atlas.merge(
        "macro_regions" => macro_regions.compact.uniq,
        "periods" => period_ids_by_region.values.flatten.uniq,
        "period_ids_by_region" => period_ids_by_region,
        "corpus_stats" => corpus_stats(documents)
      )
      row
    end

    def corpus_stats(documents)
      work_groups = documents.group_by { |document| work_identity(document) }
      author_groups = documents.reject { |document| document["author"].to_s.blank? }
        .group_by { |document| document["author"].to_s }

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
      entries_by_region = Hash.new { |hash, key| hash[key] = [] }
      entries_by_region_period = Hash.new { |hash, key| hash[key] = [] }

      entry_rows.each do |row|
        entry_id = row.fetch("id").to_s
        regions = Array(row.dig("atlas", "macro_regions")).map(&:to_s).reject(&:blank?)
        by_region = Grammar::MarkdownDocument.stringify_keys(row.dig("atlas", "period_ids_by_region").to_h)
        regions.each do |region|
          entries_by_region[region] << entry_id
          Array(by_region[region]).each do |period_id|
            entries_by_region_period[[region, period_id.to_s]] << entry_id
          end
        end
      end

      # Atlas macro-regions are human-curated. Manifest metadata may contain
      # useful geographic values that do not belong in public Atlas navigation
      # (for example documents under 他漢文), so do not auto-promote newly
      # discovered values into macro-regions.
      ordered_regions = @periodisation.macro_regions.map { |row| row.fetch("id") }

      ordered_regions.map do |region|
        period_rows = @periodisation.root_periods(region).map do |source_period|
          compile_period_row(
            region: region,
            source_period: source_period,
            entry_rows: entry_rows,
            entries_by_region_period: entries_by_region_period,
            document_stats: document_stats
          )
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
          "period_count" => count_compiled_periods(period_rows),
          "document_count" => stats.fetch("document_count"),
          "work_count" => stats.fetch("work_count"),
          "periods" => period_rows
        }
      end
    end

    def compile_period_row(region:, source_period:, entry_rows:, entries_by_region_period:, document_stats:)
      id = source_period.fetch("id")
      children = @periodisation.children_for(region, id).map do |child|
        compile_period_row(
          region: region,
          source_period: child,
          entry_rows: entry_rows,
          entries_by_region_period: entries_by_region_period,
          document_stats: document_stats
        )
      end
      all_ids = entries_by_region_period[[region, id]].uniq
      child_ids = children.flat_map { |child| Array(child["entry_ids"]) }.uniq
      direct_ids = all_ids - child_ids
      stats = document_stats.fetch(:periods)[[region, id]] || empty_stats

      {
        "id" => id,
        "label" => source_period.fetch("label", id),
        "kind" => source_period.fetch("kind", "period"),
        "parent_id" => source_period["parent_id"],
        "hidden" => source_period["hidden"] == true,
        "entry_ids" => all_ids.sort_by { |entry_id| entry_title(entry_rows, entry_id) },
        "direct_entry_ids" => direct_ids.sort_by { |entry_id| entry_title(entry_rows, entry_id) },
        "polity_count" => all_ids.length,
        "direct_polity_count" => direct_ids.length,
        "document_count" => stats.fetch("document_count"),
        "work_count" => stats.fetch("work_count"),
        "corpus_paths" => Array(source_period["corpus_paths"]),
        "article_path" => source_period["article_path"],
        "published" => source_period["published"] == true,
        "legacy_entry_ids" => Array(source_period["legacy_entry_ids"]),
        "children" => children
      }
    end

    def aggregate_document_stats(documents)
      region_rows = Hash.new { |hash, key| hash[key] = [] }
      period_rows = Hash.new { |hash, key| hash[key] = [] }

      documents.each do |document|
        region = @periodisation.normalise_macro_region(
          document["macro_region"],
          corpus_root: document["corpus_root"]
        ).presence
        next if region.blank?

        region_rows[region] << document
        @periodisation.period_ids_for_document(document).each do |period_id|
          period_rows[[region, period_id]] << document
        end
      end

      {
        regions: region_rows.transform_values { |rows| count_stats(rows) },
        periods: period_rows.transform_values { |rows| count_stats(rows.uniq { |row| row["id"].to_s }) }
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
      entry_rows.each_with_object({}) do |row, aliases|
        Array(row["legacy_ids"]).each { |legacy| aliases[legacy.to_s] = row.fetch("id").to_s }
      end
    end

    def build_indexes(entry_rows, macro_regions)
      entry_by_corpus_key = {}
      entry_rows.each do |row|
        root = row.dig("corpus", "root").to_s
        polity = row.dig("corpus", "polity").to_s
        periods = Array(row.dig("corpus", "periods")) + Array(row.dig("atlas", "periods"))
        periods.map(&:to_s).reject(&:blank?).uniq.each do |period|
          key = [root, period, polity].join("\u0000")
          entry_by_corpus_key[key] = row.fetch("id").to_s
        end
      end

      macro_region_by_corpus_root = {}
      macro_regions.each do |region|
        Array(region["corpus_roots"]).each do |root|
          macro_region_by_corpus_root[root.to_s] = region.fetch("id").to_s
        end
      end

      period_redirect_by_legacy_id = {}
      period_by_corpus_path = {}
      @periodisation.periods.each do |period|
        region = period.fetch("macro_region")
        id = period.fetch("id")
        Array(period["legacy_entry_ids"]).each do |legacy_id|
          period_redirect_by_legacy_id[legacy_id.to_s] = [region, id]
        end
        Array(period["corpus_paths"]).each do |path|
          period_by_corpus_path[path.to_s] = [region, id]
        end
      end

      {
        "entry_by_corpus_key" => entry_by_corpus_key,
        "macro_region_by_corpus_root" => macro_region_by_corpus_root,
        "period_redirect_by_legacy_id" => period_redirect_by_legacy_id,
        "period_by_corpus_path" => period_by_corpus_path
      }
    end

    def validate_compiled_payload!(payload)
      ids = payload.fetch("entries").map { |row| row.fetch("id").to_s }
      duplicates = ids.group_by(&:itself).select { |_id, rows| rows.length > 1 }.keys
      raise ArgumentError, "Duplicate atlas IDs: #{duplicates.join(', ')}" if duplicates.any?

      payload.fetch("entries").each do |row|
        unknown = Array(row["related"]).map(&:to_s) - ids
        raise ArgumentError, "Unknown atlas links for #{row['id']}: #{unknown.join(', ')}" if unknown.any?

        by_region = Grammar::MarkdownDocument.stringify_keys(row.dig("atlas", "period_ids_by_region").to_h)
        by_region.each do |region, period_ids|
          Array(period_ids).each do |period_id|
            unless @periodisation.period(region, period_id)
              raise ArgumentError, "Unknown period #{region} / #{period_id} for #{row['id']}"
            end
          end
        end
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

    def count_compiled_periods(rows)
      Array(rows).sum { |row| 1 + count_compiled_periods(row["children"]) }
    end

    def path_within?(candidate, prefix)
      candidate == prefix || candidate.start_with?(prefix + "/")
    end

    def deep_dup(value)
      Marshal.load(Marshal.dump(value))
    end
  end
end
