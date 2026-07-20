# frozen_string_literal: true

require "json"
require "pathname"
require "set"

module Atlas
  # Human-curated macro-regions plus an explicit typed period tree.
  #
  # Macro-regions are declared in content/atlas/periodisation.json.
  # Periods and subperiods are ordinary source records under:
  #
  #   content/atlas/periods/<macro-region>/<period>/metadata.json
  #
  # This makes folder meaning explicit. A directory under periods/ is a period;
  # a directory under entries/ is a polity. Corpus folder depth is no longer
  # asked to guess the object type during a web request.
  class Periodisation
    ROOT = Rails.root.join("content", "atlas", "periodisation.json")
    PERIOD_ROOT = Rails.root.join("content", "atlas", "periods")

    class Invalid < StandardError; end

    def self.default
      @default ||= new
    end

    def self.reset!
      @default = nil
    end

    attr_reader :path, :period_root

    def initialize(path: ROOT, period_root: PERIOD_ROOT)
      @path = Pathname.new(path)
      @period_root = Pathname.new(period_root)
    end

    def macro_regions
      macro_payload.fetch("macro_regions")
    end

    def macro_region(id)
      regions_by_id[id.to_s]
    end

    def excluded_corpus_roots
      Array(macro_payload["excluded_corpus_roots"])
    end

    def excluded_corpus_root?(corpus_root)
      excluded_corpus_roots.include?(corpus_root.to_s.strip)
    end

    def macro_region_for_root(corpus_root)
      root = corpus_root.to_s.strip
      return nil if excluded_corpus_root?(root)

      roots_to_regions[root]
    end

    def normalise_macro_region(value, corpus_root: nil)
      root = corpus_root.to_s.strip
      return nil if excluded_corpus_root?(root)

      candidate = value.to_s.strip
      mapped = roots_to_regions[candidate]
      return mapped if mapped.present?
      return candidate if candidate.present? && macro_region(candidate)

      macro_region_for_root(root)
    end

    def label_for(id)
      macro_region(id)&.fetch("label", nil).presence || id.to_s
    end

    def macro_region_order(id)
      macro_regions.index { |row| row["id"] == id.to_s } || macro_regions.length
    end

    def periods(region_id = nil)
      rows = period_rows
      region_id.present? ? rows.select { |row| row["macro_region"] == region_id.to_s } : rows
    end

    def period(region_id, period_id)
      periods_by_key[[region_id.to_s, period_id.to_s]]
    end

    def period!(region_id, period_id)
      period(region_id, period_id) || raise(Invalid, "Unknown Atlas period #{region_id} / #{period_id}")
    end

    def root_periods(region_id)
      requested = Array(macro_region(region_id)&.fetch("period_ids", []))
      rows = requested.filter_map { |id| period(region_id, id) }
      rows.presence || children_for(region_id, nil)
    end

    def children_for(region_id, parent_id)
      children_by_key[[region_id.to_s, parent_id.to_s]].to_a
    end

    def ancestors_for(region_id, period_id)
      row = period(region_id, period_id)
      return [] unless row

      ancestors = []
      seen = Set.new
      parent_id = row["parent_id"].to_s.presence
      while parent_id
        key = [region_id.to_s, parent_id]
        raise Invalid, "Cycle in Atlas period tree at #{key.join(' / ')}" if seen.include?(key)
        seen << key
        parent = period(*key)
        raise Invalid, "Unknown parent period #{key.join(' / ')}" unless parent
        ancestors.unshift(parent)
        parent_id = parent["parent_id"].to_s.presence
      end
      ancestors
    end

    def descendant_ids(region_id, period_id, include_self: true)
      ids = []
      walk = lambda do |row|
        ids << row.fetch("id")
        children_for(region_id, row.fetch("id")).each { |child| walk.call(child) }
      end
      row = period(region_id, period_id)
      walk.call(row) if row
      include_self ? ids : ids.drop(1)
    end

    def period_order(region_id, period_id)
      row = period(region_id, period_id)
      return periods(region_id).length unless row

      [ancestors_for(region_id, period_id), row]
        .flatten
        .map { |candidate| candidate["order"].to_i }
    end

    def period_for_legacy_entry_id(id)
      legacy_period_index[id.to_s]
    end

    def period_ids_for_document(document)
      region = normalise_macro_region(document["macro_region"], corpus_root: document["corpus_root"])
      return [] if region.blank?

      paths = [document["path"], document["folder_path"]].map(&:to_s).reject(&:blank?)
      manifest_periods = [document["period"]].map(&:to_s).reject(&:blank?)
      matched_period_ids(region, paths: paths, manifest_periods: manifest_periods)
    end

    def period_ids_for_entry(root:, paths:, manifest_periods:, explicit_ids: [], macro_regions: [])
      regions = Array(macro_regions).map(&:to_s).reject(&:blank?)
      fallback = macro_region_for_root(root)
      regions << fallback if regions.empty? && fallback.present?
      explicit = Array(explicit_ids).map(&:to_s).reject(&:blank?)

      regions.each_with_object({}) do |region, result|
        ids = explicit.select { |id| period(region, id) }
        if ids.any?
          ids = ids.flat_map do |id|
            ancestors_for(region, id).map { |ancestor| ancestor.fetch("id") } + [id]
          end
          ids = sort_period_ids(region, ids.uniq)
        else
          ids = matched_period_ids(region, paths: paths, manifest_periods: manifest_periods)
        end
        result[region] = ids
      end
    end

    def validate!
      mapped_excluded_roots = macro_regions.flat_map { |region| Array(region["corpus_roots"]) } & excluded_corpus_roots
      if mapped_excluded_roots.any?
        raise Invalid, "Excluded corpus roots are still mapped into the Atlas: #{mapped_excluded_roots.join(', ')}"
      end

      macro_regions.each do |region|
        region_id = region.fetch("id")
        Array(region["period_ids"]).each do |period_id|
          row = period(region_id, period_id)
          raise Invalid, "Missing root period #{region_id} / #{period_id}" unless row
          if row["parent_id"].present?
            raise Invalid, "Configured root period has a parent: #{region_id} / #{period_id}"
          end
        end
      end

      periods_by_key.each_value do |row|
        parent_id = row["parent_id"].to_s.presence
        if parent_id && !period(row.fetch("macro_region"), parent_id)
          raise Invalid, "Missing parent #{row['macro_region']} / #{parent_id} for #{row['id']}"
        end
        ancestors_for(row.fetch("macro_region"), row.fetch("id"))
      end

      Atlas::UnicodeGuard.validate!(macro_payload, context: "atlas macro-regions")
      Atlas::UnicodeGuard.validate!(period_rows, context: "atlas period sources")
      true
    end

    private

    def matched_period_ids(region, paths:, manifest_periods:)
      paths = Array(paths).map(&:to_s).reject(&:blank?)
      manifest_periods = Array(manifest_periods).map(&:to_s).reject(&:blank?)

      direct = periods(region).select do |row|
        path_match = Array(row["corpus_paths"]).any? do |prefix|
          paths.any? { |candidate| path_within?(candidate, prefix) }
        end
        value_match = (Array(row["manifest_periods"]) & manifest_periods).any?
        alias_match = (Array(row["aliases"]) & manifest_periods).any?
        id_match = manifest_periods.include?(row.fetch("id"))
        path_match || value_match || alias_match || id_match
      end

      # A broad parent path and a specific child path often both match. Keeping
      # both is intentional: the child page gets the item, while its ancestors
      # retain aggregate counts and breadcrumbs.
      ids = direct.flat_map do |row|
        ancestors_for(region, row.fetch("id")).map { |ancestor| ancestor.fetch("id") } + [row.fetch("id")]
      end
      sort_period_ids(region, ids.uniq)
    end

    def sort_period_ids(region, ids)
      ids.sort_by do |id|
        chain = ancestors_for(region, id) + [period(region, id)]
        [chain.length, *chain.map { |row| row["order"].to_i }, id]
      end
    end

    def path_within?(candidate, prefix)
      candidate == prefix || candidate.start_with?(prefix + "/")
    end

    def macro_payload
      @macro_payload ||= begin
        raw = path.binread.force_encoding(Encoding::UTF_8)
        raise Invalid, "Atlas periodisation is not valid UTF-8" unless raw.valid_encoding?
        parsed = JSON.parse(raw)
        raise Invalid, "Atlas periodisation must be a mapping" unless parsed.is_a?(Hash)
        raise Invalid, "Atlas macro_regions must be a list" unless parsed["macro_regions"].is_a?(Array)

        parsed["excluded_corpus_roots"] = Array(parsed["excluded_corpus_roots"])
          .map(&:to_s).map(&:strip).reject(&:empty?).uniq

        parsed["macro_regions"] = parsed["macro_regions"].map do |row|
          normalized = Grammar::MarkdownDocument.stringify_keys(row.to_h)
          normalized["id"] = normalized["id"].to_s
          normalized["label"] = normalized["label"].to_s.presence || normalized["id"]
          normalized["corpus_roots"] = Array(normalized["corpus_roots"]).map(&:to_s).reject(&:blank?).uniq
          normalized["period_ids"] = Array(normalized["period_ids"] || normalized["periods"]).map do |value|
            value.is_a?(Hash) ? value["id"].to_s : value.to_s
          end.reject(&:blank?).uniq
          normalized.delete("periods")
          normalized
        end
        parsed.freeze
      end
    rescue JSON::ParserError => error
      raise Invalid, "Invalid Atlas periodisation JSON: #{error.message}"
    end

    def period_rows
      @period_rows ||= begin
        paths = Dir.glob(period_root.join("**", "metadata.json").to_s).sort
        rows = paths.map do |filename|
          metadata_path = Pathname.new(filename)
          raw = metadata_path.binread.force_encoding(Encoding::UTF_8)
          raise Invalid, "Atlas period metadata is not valid UTF-8: #{metadata_path}" unless raw.valid_encoding?
          parsed = JSON.parse(raw)
          raise Invalid, "Atlas period metadata must be a mapping: #{metadata_path}" unless parsed.is_a?(Hash)

          row = Grammar::MarkdownDocument.stringify_keys(parsed)
          row["id"] = row.fetch("id").to_s
          row["kind"] = row.fetch("kind", "period").to_s
          row["label"] = row.fetch("label", row["id"]).to_s
          row["macro_region"] = row.fetch("macro_region").to_s
          row["parent_id"] = row["parent_id"].to_s.presence
          row["order"] = row.fetch("order", 0).to_i
          row["corpus_paths"] = Array(row["corpus_paths"]).map(&:to_s).reject(&:blank?).uniq
          row["manifest_periods"] = Array(row["manifest_periods"]).map(&:to_s).reject(&:blank?).uniq
          row["aliases"] = Array(row["aliases"]).map(&:to_s).reject(&:blank?).uniq
          row["legacy_entry_ids"] = Array(row["legacy_entry_ids"]).map(&:to_s).reject(&:blank?).uniq
          row["source_metadata_path"] = metadata_path.relative_path_from(period_root.parent).to_s.tr("\\", "/")
          article_path = metadata_path.dirname.join("index.md").relative_path_from(period_root.parent).to_s.tr("\\", "/")
          row["article_path"] = article_path
          row["published"] = period_root.parent.join(article_path).file?
          row
        rescue JSON::ParserError => error
          raise Invalid, "Invalid Atlas period JSON in #{metadata_path}: #{error.message}"
        end

        duplicates = rows.group_by { |row| [row.fetch("macro_region"), row.fetch("id")] }
          .select { |_key, values| values.length > 1 }
        unless duplicates.empty?
          raise Invalid, "Duplicate Atlas period IDs: #{duplicates.keys.map { |key| key.join(' / ') }.join(', ')}"
        end
        rows.freeze
      end
    end

    def periods_by_key
      @periods_by_key ||= period_rows.index_by { |row| [row.fetch("macro_region"), row.fetch("id")] }
    end

    def children_by_key
      @children_by_key ||= begin
        index = Hash.new { |hash, key| hash[key] = [] }
        period_rows.each do |row|
          index[[row.fetch("macro_region"), row["parent_id"].to_s]] << row
        end
        index.each_value { |rows| rows.sort_by! { |row| [row["order"].to_i, row.fetch("label")] } }
        index
      end
    end

    def legacy_period_index
      @legacy_period_index ||= period_rows.each_with_object({}) do |row, index|
        Array(row["legacy_entry_ids"]).each do |legacy_id|
          index[legacy_id] = [row.fetch("macro_region"), row.fetch("id")]
        end
      end
    end

    def regions_by_id
      @regions_by_id ||= macro_regions.index_by { |row| row.fetch("id") }
    end

    def roots_to_regions
      @roots_to_regions ||= macro_regions.each_with_object({}) do |row, index|
        Array(row["corpus_roots"]).each { |root| index[root] = row.fetch("id") }
      end
    end
  end
end
