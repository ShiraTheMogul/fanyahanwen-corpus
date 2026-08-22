# frozen_string_literal: true

require "json"
require "pathname"

# Enriches the search-facing metadata view with authority-derived chronology,
# explicit category arrays, and explicitly linked compilation chronology.
# metadata.json remains the scholarly source of truth and is never rewritten.
module HistoricalMetadataDating
  DATE_RESOLUTION_FIELDS = {
    "date_resolution_source" => :source,
    "date_resolution_confidence" => :confidence,
    "date_resolution_authority_kind" => :authority_kind,
    "date_resolution_authority_id" => :authority_id,
    "date_resolution_authority_name" => :authority_name,
    "date_resolution_country" => :country
  }.freeze

  def search_metadata_for_path(rel_path)
    result = super
    metadata = document_metadata_for_path(rel_path)

    result["categories"] = Array(metadata["categories"])
      .map(&:to_s).map(&:strip).reject(&:empty?).uniq

    if (compilation = linked_compilation_for_path(rel_path))
      parent = compilation.fetch(:metadata)
      parent_start, parent_end, parent_resolution = historical_year_bounds(parent)
      result.merge!(
        "compilation_work_id" => integer_or_nil(parent["work_id"]),
        "compilation_title" => parent["title"].to_s.presence,
        "compilation_date_text" => parent["date_label"].to_s.presence,
        "compilation_year_start" => parent_start,
        "compilation_year_end" => parent_end,
        "compilation_period" => parent["period"].to_s.presence,
        "compilation_polity" => parent["polity"].to_s.presence,
        "compilation_categories" => Array(parent["categories"]).map(&:to_s).map(&:strip).reject(&:empty?).uniq,
        "compilation_metadata_path" => compilation.fetch(:path).relative_path_from(@root).to_s.tr("\\", "/"),
        "compilation_date_resolution_source" => parent_resolution&.source,
        "compilation_date_resolution_confidence" => parent_resolution&.confidence
      ).compact!
    end

    # Explicit numeric metadata always wins. Authority data only derives missing
    # numeric bounds from a date label such as 元和三年 or 孝徳天皇三年.
    if result["year_start"].nil? && result["year_end"].nil? && result["date_text"].present?
      resolution = historical_date_resolution(result)
      if resolution&.resolved?
        result["year_start"] = resolution.year_start
        result["year_end"] = resolution.year_end
        DATE_RESOLUTION_FIELDS.each do |field, method_name|
          value = resolution.public_send(method_name)
          result[field] = value unless value.nil? || value.to_s.empty?
        end
      end
    end

    result
  rescue StandardError => e
    @logger&.warn("[corpus_metadata_store] historical authority enrichment skipped for #{rel_path}: #{e.class}: #{e.message}")
    result || super
  end

  # Manifest fingerprints include every metadata file which explicitly
  # contributes to a row. Merely being nested inside a compilation directory is
  # insufficient: child contained_in or parent worklist must declare the link.
  def metadata_dependency_paths_for(rel_path)
    metadata_dependency_paths_for_metadata_path(metadata_path_for(rel_path))
  end

  def metadata_dependency_paths_for_metadata_path(child_path)
    # Callers normally supply one metadata Pathname, but manifest extensions and
    # future metadata stores may already have expanded that into a collection.
    # Treat the argument as a dependency collection at this boundary instead of
    # passing an Array to Pathname(), which aborts a full manifest rebuild.
    child_paths = Array(child_path).flatten.compact.filter_map do |path|
      next if path.to_s.strip.empty?

      Pathname(path.to_s)
    rescue TypeError, ArgumentError
      nil
    end

    child_paths.flat_map do |path|
      paths = [path]
      linked = linked_compilation_for_metadata_path(path)
      paths << linked.fetch(:path) if linked
      paths
    end.uniq
  end

  private

  def historical_year_bounds(metadata)
    explicit_start = integer_or_nil(metadata["year_start"] || metadata["year"])
    explicit_end = integer_or_nil(metadata["year_end"] || metadata["year"])
    return [explicit_start || explicit_end, explicit_end || explicit_start, nil] if explicit_start || explicit_end

    resolution = historical_date_resolution(metadata_for_resolver(metadata))
    if resolution&.resolved?
      [resolution.year_start, resolution.year_end, resolution]
    else
      [nil, nil, nil]
    end
  end

  def historical_date_resolution(metadata)
    data = metadata.to_h.stringify_keys
    key = %w[date_text date_label corpus_root nation period polity region year_start year_end year]
      .map { |field| data[field].to_s }.freeze
    @historical_date_resolution_cache ||= {}
    return @historical_date_resolution_cache[key] if @historical_date_resolution_cache.key?(key)

    @historical_date_resolution_cache[key] = historical_date_resolver.resolve(metadata: data)
  end

  def metadata_for_resolver(metadata)
    data = metadata.to_h.stringify_keys
    {
      "date_label" => data["date_label"].to_s,
      "date_text" => data["date_text"].to_s.presence || data["date_label"].to_s,
      "corpus_root" => data["corpus_root"].to_s,
      "nation" => data["nation"].to_s,
      "period" => data["period"].to_s,
      "polity" => data["polity"].to_s,
      "region" => data["region"].to_s,
      "year_start" => data["year_start"],
      "year_end" => data["year_end"],
      "year" => data["year"]
    }
  end

  def historical_date_resolver
    @historical_date_resolver ||= HistoricalDateResolver.new(store: HistoricalAuthorityStore.default)
  end

  def linked_compilation_for_path(rel_path)
    linked_compilation_for_metadata_path(metadata_path_for(rel_path))
  end

  def linked_compilation_for_metadata_path(child_path)
    return nil unless child_path

    child_path = Pathname(child_path)
    child = read_json(child_path)
    child_work_id = integer_or_nil(child["work_id"])
    declared_parent_ids = Array(child["contained_in"]).filter_map do |relation|
      next unless relation.is_a?(Hash)

      integer_or_nil(relation["work_id"])
    end.uniq

    dir = child_path.dirname.parent
    while dir == @root || dir.to_s.start_with?(@root.to_s + File::SEPARATOR)
      candidate = dir.join("metadata.json")
      if candidate.file?
        parent = read_json(candidate)
        if truthy_historical_value?(parent["is_compilation"])
          parent_work_id = integer_or_nil(parent["work_id"])
          parent_declared = parent_work_id && declared_parent_ids.include?(parent_work_id)
          child_listed = child_work_id && Array(parent["worklist"]).any? do |entry|
            entry.is_a?(Hash) && integer_or_nil(entry["work_id"]) == child_work_id
          end
          return { path: candidate, metadata: parent } if parent_declared || child_listed
        end
      end

      break if dir == @root
      dir = dir.parent
    end

    nil
  end

  def truthy_historical_value?(value)
    value == true || value.to_s.strip.match?(/\A(?:1|true|yes)\z/i)
  end

  # Some repository metadata files are UTF-8 with a BOM. Ruby's JSON parser
  # does not consume U+FEFF, so remove only that leading encoding marker after
  # validating the bytes. This preserves all source text and metadata bytes.
  def read_json(path)
    key = path.to_s
    @cache.fetch(key) do
      raw = path.binread.force_encoding(Encoding::UTF_8)
      raise JSON::ParserError, "invalid UTF-8" unless raw.valid_encoding?

      @cache[key] = JSON.parse(raw.sub(/\A\uFEFF/, ""))
    rescue JSON::ParserError => e
      @logger&.warn("[corpus_metadata_store] invalid JSON #{relative_display(path)}: #{e.message}")
      @cache[key] = {}
    rescue SystemCallError => e
      @logger&.warn("[corpus_metadata_store] cannot read #{relative_display(path)}: #{e.class}: #{e.message}")
      @cache[key] = {}
    end
  end
end
