#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "set"
require "time"
require "yaml"

# Generates staged JSON sidecar metadata from the legacy per-txt header audit.
#
# This is intentionally a dry-run/staging tool. It does not write into the
# corpus unless --apply is explicitly supplied. The normal dry-run output uses
# short work_id-based paths so the review ZIP is not destroyed by long corpus
# titles. work_manifest.csv records the real apply destination for each work.
class CorpusMetadataJsonDryRun
  DEFAULT_KEY_MAP = "config/corpus_metadata/json_generation_map.yml"
  DEFAULT_GEOGRAPHY_MAP = "config/corpus_metadata/geography_period_map.yml"
  DEFAULT_COMPILATION_MAP = "config/corpus_metadata/compilation_map.yml"

  FILES_CSV = "files.csv"
  METADATA_ROWS_CSV = "metadata_rows.csv"

  attr_reader :options

  def initialize(options)
    @options = options
    @audit_output = Pathname(options.fetch(:audit_output)).expand_path
    @output_root = Pathname(options.fetch(:output)).expand_path
    @corpus_root = options[:corpus_root] ? Pathname(options[:corpus_root]).expand_path : nil
    @key_map_path = Pathname(options.fetch(:key_map)).expand_path
    @geography_map_path = Pathname(options.fetch(:geography_map)).expand_path
    @compilation_map_path = Pathname(options.fetch(:compilation_map)).expand_path
    @geography_suggestions_path = options[:geography_suggestions] ? Pathname(options[:geography_suggestions]).expand_path : nil
    @apply = options.fetch(:apply)
    @mirror_staged_paths = options.fetch(:mirror_staged_paths)
    @max_folders = options[:max_folders]&.to_i
    @max_files = options[:max_files]&.to_i
    @work_id_start = options.fetch(:work_id_start).to_i
    @document_id_start = options.fetch(:document_id_start).to_i
    @edition_id_start = options.fetch(:edition_id_start).to_i
    @id_registry_path = options[:id_registry] ? Pathname(options[:id_registry]).expand_path : nil
    @id_registry_output_path = nil
    @json_output_mode = options.fetch(:json_output_mode).to_s
    @source_mode = options.fetch(:source_mode).to_s
    @progress_every = options.fetch(:progress_every).to_i

    @key_map = load_yaml(@key_map_path)
    @geography_map = load_yaml(@geography_map_path)
    @compilation_map = load_yaml(@compilation_map_path)
    @geography_suggestions = load_geography_suggestions
    @works = {}
    @docs_by_path = {}
    @ignored_rows = []
    @unknown_rows = []
    @conflicts = []
    @fold_decisions = []
    @work_fold_cache = {}
    @compilation_rule_cache = {}
    @contained_work_proposals = []
    @contained_work_payloads_by_work_id = Hash.new { |h, k| h[k] = [] }
    @id_registry_rows = []
    @id_registry_existing = load_id_registry
    @id_registry_assigned = {}
    @id_registry_row_keys = Set.new
    @contained_work_proposal_ids = Set.new
    @compilation_root_cache = {}
    @compilation_containers_cache = {}
    @proposal_counts_by_work_id = Hash.new(0)
    @proposal_document_counts_by_work_id = Hash.new(0)
    @conflict_counts_by_work = Hash.new(0)
    @fold_decision_counts_by_work = Hash.new(0)
    @next_ids = {}
    @metadata_records_written = 0
    @started_at = Time.now.utc
  end

  def run
    progress "validating inputs"
    validate!
    prepare_output!
    progress "loading file list (source_mode=#{@source_mode})"
    load_files!
    progress "loaded #{@docs_by_path.length} documents in #{@works.length} work folders"
    progress "loading legacy metadata rows"
    load_metadata_rows!
    progress "loaded legacy metadata rows; ignored=#{@ignored_rows.length}, unknown=#{@unknown_rows.length}"
    progress "assigning IDs"
    assign_ids!
    progress "writing staged metadata (mode=#{@apply ? 'apply' : @json_output_mode})"
    write_json_files!
    progress "writing reports"
    write_reports!
    progress "finished"
    warn "[json-dry-run] wrote #{@metadata_records_written} metadata records (#{@works.length} folder works + #{@contained_work_proposals.length} contained works) to #{staged_output_description}"
    warn "[json-dry-run] mode=#{@apply ? 'APPLY' : 'DRY RUN'}"
  end

  private

  Work = Struct.new(
    :folder, :documents, :work_values, :work_lists, :contributors, :identifiers,
    :sources, :source_categories, :geography_values, :unknown_rows, :ignored_rows,
    :work_id, keyword_init: true
  )

  Doc = Struct.new(
    :path, :parent_folder, :file_name, :metadata_rows, :body_start_line,
    :values, :lists, :contributors, :identifiers, :contained_in, :external_refs,
    :geography_values, :document_id, keyword_init: true
  )

  def validate!
    raise ArgumentError, "Audit output directory does not exist: #{@audit_output}" unless @audit_output.directory?
    raise ArgumentError, "Missing #{FILES_CSV} in #{@audit_output}" unless @audit_output.join(FILES_CSV).file?
    raise ArgumentError, "Missing #{METADATA_ROWS_CSV} in #{@audit_output}; rerun audit with --include-rows" unless @audit_output.join(METADATA_ROWS_CSV).file?
    raise ArgumentError, "Key map does not exist: #{@key_map_path}" unless @key_map_path.file?
    raise ArgumentError, "Geography map does not exist: #{@geography_map_path}" unless @geography_map_path.file?
    raise ArgumentError, "Compilation map does not exist: #{@compilation_map_path}" unless @compilation_map_path.file?
    raise ArgumentError, "--apply requires --corpus-root" if @apply && !@corpus_root
    unless %w[jsonl files both].include?(@json_output_mode)
      raise ArgumentError, "--json-output-mode must be one of: jsonl, files, both"
    end
    unless %w[clean all raw].include?(@source_mode)
      raise ArgumentError, "--source-mode must be one of: clean, all, raw"
    end
  end

  def prepare_output!
    FileUtils.mkdir_p(@output_root)
    FileUtils.mkdir_p(staged_root) if write_staged_files?
    @id_registry_output_path = Pathname(options[:write_id_registry] || @output_root.join("metadata_id_registry.csv")).expand_path
  end

  def write_staged_files?
    @apply || %w[files both].include?(@json_output_mode)
  end

  def write_staged_jsonl?
    !@apply && %w[jsonl both].include?(@json_output_mode)
  end

  def jsonl_path
    @output_root.join("staged_metadata.jsonl")
  end

  def staged_output_description
    return @corpus_root.to_s if @apply
    return "#{jsonl_path} and #{staged_root}" if @json_output_mode == "both"
    return staged_root.to_s if @json_output_mode == "files"

    jsonl_path.to_s
  end

  def progress(message)
    warn "[json-dry-run] #{Time.now.utc.iso8601} #{message}"
  end

  def maybe_progress(count, label)
    return unless @progress_every.positive?
    return unless (count % @progress_every).zero?

    progress "#{label}: #{count}"
  end

  def staged_root
    @output_root.join("staged_metadata")
  end

  def load_yaml(path)
    YAML.safe_load(path.read, aliases: false) || {}
  rescue Psych::SyntaxError => error
    raise ArgumentError, "Invalid YAML in #{path}: #{error.message}"
  end


  def load_id_registry
    return {} unless @id_registry_path&.file?

    registry = {}
    CSV.foreach(@id_registry_path, headers: true, encoding: "bom|utf-8") do |row|
      kind = presence(row["kind"])
      identity_key = presence(row["identity_key"]) || [kind, row["path"].to_s].join(":")
      id = row["id"].to_i
      next unless kind && identity_key && id.positive?

      registry[[kind, identity_key]] = {
        id: id,
        path: presence(row["path"]),
        title: presence(row["title"]),
        parent_work_id: presence(row["parent_work_id"]),
        source_document_id: presence(row["source_document_id"]),
        status: presence(row["status"])
      }
    end
    registry
  end

  def load_geography_suggestions
    return {} unless @geography_suggestions_path&.file?

    suggestions = {}
    CSV.foreach(@geography_suggestions_path, headers: true, encoding: "bom|utf-8") do |row|
      key = [row["raw_key"].to_s, row["value"].to_s]
      suggestions[key] = {
        "corpus_root" => presence(row["corpus_root"]),
        "macro_region" => presence(row["macro_region"]),
        "period" => presence(row["period"]),
        "polity" => presence(row["polity"]),
        "region" => presence(row["region"]),
        "confidence" => presence(row["confidence"]),
        "source" => presence(row["source"]),
        "notes" => presence(row["notes"])
      }.compact
    end
    suggestions
  end

  def load_files!
    count = 0
    selected_folders = Set.new
    CSV.foreach(@audit_output.join(FILES_CSV), headers: true, encoding: "bom|utf-8") do |row|
      path = row.fetch("path").to_s
      next if excluded_path?(path)

      parent = work_folder_for_path(path, row.fetch("parent_folder").to_s)
      if @max_folders && !selected_folders.include?(parent)
        next if selected_folders.length >= @max_folders
        selected_folders << parent
      end
      break if @max_files && count >= @max_files

      doc = Doc.new(
        path: path,
        parent_folder: parent,
        file_name: row.fetch("file_name").to_s,
        metadata_rows: row.fetch("metadata_rows").to_i,
        body_start_line: row.fetch("body_start_line").to_i,
        values: Hash.new { |h, k| h[k] = [] },
        lists: Hash.new { |h, k| h[k] = [] },
        contributors: [],
        identifiers: [],
        contained_in: [],
        external_refs: [],
        geography_values: []
      )

      work = (@works[parent] ||= Work.new(
        folder: parent,
        documents: [],
        work_values: Hash.new { |h, k| h[k] = [] },
        work_lists: Hash.new { |h, k| h[k] = [] },
        contributors: [],
        identifiers: [],
        sources: [],
        source_categories: [],
        geography_values: [],
        unknown_rows: [],
        ignored_rows: []
      ))
      work.documents << doc
      @docs_by_path[path] = doc
      count += 1
      maybe_progress(count, "files loaded")
    end
  end

  def excluded_path?(path)
    text = path.to_s
    file_name = File.basename(text)
    return true if Array(@key_map.dig("exclude_path_prefixes")).any? { |prefix| text.start_with?(prefix.to_s) }
    return true if Array(@key_map.dig("exclude_file_names")).any? { |name| file_name == name.to_s }
    return true if source_mode_excluded_path?(text)

    Array(@key_map.dig("exclude_path_patterns")).any? do |pattern|
      begin
        text.match?(Regexp.new(pattern.to_s))
      rescue RegexpError
        false
      end
    end
  end

  def source_mode_excluded_path?(path)
    parts = path.to_s.split("/")
    has_clean = parts.include?("clean")
    has_raw = parts.include?("raw")

    case @source_mode
    when "clean"
      has_raw
    when "raw"
      has_clean
    else
      false
    end
  end

  def source_bucket_roots
    @source_bucket_roots ||= Array(@key_map.dig("source_buckets")).map(&:to_s)
  end

  def source_bucket_path?(path)
    source_bucket_roots.include?(path.to_s.split("/").first)
  end

  def source_bucket_work_folder_for_path(path)
    parts = path.to_s.split("/")
    return nil unless source_bucket_roots.include?(parts[0])

    mode_index = %w[clean raw].include?(parts[1]) ? 1 : nil
    base_parts = mode_index ? parts[0..mode_index] : [parts[0]]
    rest = parts[(mode_index ? 2 : 1)..] || []
    return nil if rest.empty?

    # Source buckets like 維基大典 can store pages as direct txt files under
    # clean/. Treat each direct file as its own virtual work for JSON review,
    # otherwise the whole clean folder becomes one fake work called “clean”.
    if rest.length == 1 && File.extname(rest.first) == ".txt"
      base_parts + [file_title(rest.first)]
    else
      base_parts + rest[0..-2]
    end.join("/")
  end

  def work_folder_for_path(path, fallback_parent)
    compilation_root_for_path(path) || source_bucket_work_folder_for_path(path) || fallback_parent
  end

  def compilation_root_for_path(path)
    @compilation_root_cache[path] ||= begin
      parts = path.to_s.split("/")
      Array(@compilation_map["known_compilations"]).each do |rule|
        match = rule.fetch("match", {}) || {}
        Array(match["folder_name"] || match["folder_basename"]).each do |name|
          index = parts.index(name.to_s)
          return parts[0..index].join("/") if index
        end
      end
      nil
    end
  end

  def load_metadata_rows!
    count = 0
    CSV.foreach(@audit_output.join(METADATA_ROWS_CSV), headers: true, encoding: "bom|utf-8") do |row|
      count += 1
      maybe_progress(count, "metadata rows read")
      path = row.fetch("path").to_s
      doc = @docs_by_path[path]
      next unless doc

      raw_key = row.fetch("raw_key").to_s
      value = row.fetch("value").to_s.strip
      next if value.empty?

      work = @works.fetch(doc.parent_folder)
      key_rule = key_rule_for(raw_key)

      if ignored_key?(raw_key)
        record_ignored(work, doc, row, "ignored_key")
        next
      end

      unless key_rule
        record_unknown(work, doc, row)
        next
      end

      apply_row(work, doc, raw_key, value, key_rule)
    end
  end

  def key_rule_for(raw_key)
    @key_map.dig("keys", raw_key)
  end

  def ignored_key?(raw_key)
    Array(@key_map["ignored_keys"]).include?(raw_key)
  end

  def record_ignored(work, doc, row, reason)
    entry = row_to_issue(work, doc, row, reason)
    work.ignored_rows << entry
    @ignored_rows << entry
  end

  def record_unknown(work, doc, row)
    entry = row_to_issue(work, doc, row, "unknown_key")
    work.unknown_rows << entry
    @unknown_rows << entry
  end

  def row_to_issue(work, doc, row, reason)
    {
      work_folder: work.folder,
      path: doc.path,
      line_number: row["line_number"],
      raw_key: row["raw_key"],
      canonical_key: row["canonical_key"],
      value: row["value"],
      reason: reason
    }
  end

  def apply_row(work, doc, raw_key, value, rule)
    type = rule.fetch("type").to_s
    target = rule.fetch("target").to_s
    level = rule.fetch("level").to_s

    if type == "geography"
      if raw_key == "TIMES" && date_like?(value)
        add_scalar(work, doc, :document, "date_label", value)
        return
      end

      mapped = geography_for(raw_key, value)
      row = mapped.merge("raw_key" => raw_key, "value" => value)
      doc.geography_values << row
      work.geography_values << row
      return
    end

    target_level = resolve_level(level, target)

    case type
    when "scalar"
      add_scalar(work, doc, target_level, target, value)
    when "list"
      add_list(work, doc, target_level, target, split_list(value, rule))
    when "contributor"
      entries = split_list(value, rule).map { |name| { "name" => name, "role" => rule["role"] }.compact }
      if target_level == :document
        doc.contributors.concat(entries)
      else
        doc.contributors.concat(entries)
        work.contributors.concat(entries)
      end
    when "identifier"
      entries = split_list(value, rule).map { |identifier| { "scheme" => rule["scheme"], "value" => identifier }.compact }
      if target_level == :document
        doc.identifiers.concat(entries)
      else
        doc.identifiers.concat(entries)
        work.identifiers.concat(entries)
      end
    when "containment_hint"
      doc.contained_in << { "legacy_key" => target, "value" => value }
    when "external_ref"
      doc.external_refs << { "kind" => rule["kind"], "value" => value }
    else
      add_scalar(work, doc, target_level, target, value)
    end
  end

  def resolve_level(level, target)
    case level
    when "work" then :work
    when "document" then :document
    else
      %w[title date_label name].include?(target) ? :auto : :work
    end
  end

  # Work-level legacy fields are also attached to the source document. Later
  # fold-up decides whether the value is truly shared enough to lift to work
  # level. This prevents one huge collection folder from becoming one fake work.
  def add_scalar(work, doc, target_level, target, value)
    if target_level == :document
      doc.values[target] << value
    elsif target_level == :auto
      doc.values[target] << value
      work.work_values[target] << value
    else
      doc.values[target] << value
      work.work_values[target] << value
    end
  end

  def add_list(work, doc, target_level, target, values)
    return if values.empty?

    if target_level == :document
      doc.lists[target].concat(values)
    elsif target_level == :auto
      doc.lists[target].concat(values)
      work.work_lists[target].concat(values)
    else
      doc.lists[target].concat(values)
      work.work_lists[target].concat(values)
    end
  end

  def split_list(value, rule = nil)
    pattern = rule && rule["separators"] ? rule["separators"] : @key_map.fetch("list_separators", "[，、；;,|]")
    value.to_s.split(Regexp.new(pattern)).map(&:strip).reject(&:empty?).uniq
  rescue RegexpError
    [value.to_s.strip].reject(&:empty?)
  end

  def geography_for(raw_key, value)
    explicit_geography(value) || @geography_suggestions[[raw_key, value]] || inferred_geography(raw_key, value) || {}
  end

  def explicit_geography(value)
    explicit = @geography_map.dig("values", value)
    return nil unless explicit

    explicit.transform_keys(&:to_s).slice("corpus_root", "macro_region", "period", "polity", "region", "confidence", "notes").compact
  end

  def inferred_geography(raw_key, value)
    if (root = @geography_map.dig("corpus_roots", value))
      return { "corpus_root" => value, "macro_region" => root["macro_region"], "confidence" => "high", "source" => "corpus_root" }.compact
    end

    case raw_key
    when "REGION"
      { "region" => value, "confidence" => "low", "source" => "region_fallback" }
    when "TIMES"
      date_like?(value) ? { "date_label" => value, "confidence" => "medium", "source" => "times_date_fallback" } : { "period" => value, "confidence" => "low", "source" => "times_fallback" }
    else
      {}
    end
  end

  def date_like?(value)
    text = value.to_s.strip
    return false if text.empty?
    return true if text.match?(/\A\d{1,4}(?:年)?\z/)
    return true if text.match?(/\A\d{1,4}[\-–至]\d{1,4}(?:年)?\z/)
    return true if text.match?(/\A(?:公元|西元)?\d{1,4}年(?:\d{1,2}月(?:\d{1,2}日)?)?\z/)
    return true if text.match?(/\A民國\d{1,3}年/)

    false
  end

  def assign_ids!
    seed_next_ids!
    @works.keys.sort.each do |folder|
      work = @works.fetch(folder)
      work.work_id = registry_id("work", work_identity_key(folder), path: folder, title: folder_title(folder), status: "active")
      work.documents.sort_by!(&:path)
      work.documents.each do |doc|
        doc.document_id = registry_id("document", document_identity_key(doc.path), path: doc.path, title: file_title(doc.file_name), parent_work_id: work.work_id, status: "active")
      end
      maybe_progress(@id_registry_rows.length, "IDs assigned")
    end
  end

  def seed_next_ids!
    @next_ids = {
      "work" => [@work_id_start, max_existing_id("work") + 1].max,
      "document" => [@document_id_start, max_existing_id("document") + 1].max,
      "edition" => [@edition_id_start, max_existing_id("edition") + 1].max
    }
  end

  def max_existing_id(kind)
    @id_registry_existing.each_with_object([]) do |((existing_kind, _identity_key), row), ids|
      ids << row[:id] if existing_kind == kind
    end.max.to_i
  end

  def registry_id(kind, identity_key, path:, title: nil, parent_work_id: nil, source_document_id: nil, status: nil)
    key = [kind, identity_key]
    existing = @id_registry_existing[key]
    id = existing ? existing[:id] : next_registry_id(kind)
    @id_registry_assigned[key] = id
    unless @id_registry_row_keys.include?(key)
      @id_registry_row_keys << key
      @id_registry_rows << {
        kind: kind,
        id: id,
        identity_key: identity_key,
        path: path,
        title: title,
        parent_work_id: parent_work_id,
        source_document_id: source_document_id,
        status: status || (existing && existing[:status]) || "active"
      }
    end
    id
  end

  def next_registry_id(kind)
    id = @next_ids.fetch(kind)
    @next_ids[kind] = id + 1
    id
  end

  def work_identity_key(folder)
    "work:#{folder}"
  end

  def document_identity_key(path)
    "document:#{path}"
  end

  def contained_work_identity_key(work, title)
    "contained_work:#{work.folder}:#{normalise_contained_work_title(title)}"
  end

  def edition_identity_key(work, title)
    "edition:#{work.folder}:#{normalise_contained_work_title(title)}"
  end

  def write_json_files!
    written = 0
    jsonl_io = write_staged_jsonl? ? File.open(jsonl_path, "w:UTF-8") : nil

    @works.keys.sort.each do |folder|
      work = @works.fetch(folder)
      payload = build_payload(work)
      payloads = [payload] + Array(@contained_work_payloads_by_work_id[work.work_id])

      payloads.each do |record|
        if jsonl_io
          jsonl_io.write(JSON.generate(record))
          jsonl_io.write("\n")
        end

        if write_staged_files?
          destination = metadata_destination_for_record(work, record)
          FileUtils.mkdir_p(destination.dirname)
          destination.write(JSON.pretty_generate(record) + "\n")
        end

        written += 1
        maybe_progress(written, "metadata records written")
      end
    end
    @metadata_records_written = written
  ensure
    jsonl_io&.close
  end

  def json_destination(work)
    if @apply
      @corpus_root.join(work.folder).join("metadata.json")
    elsif !write_staged_files?
      "#{jsonl_path}#work_id=#{work.work_id}"
    elsif @mirror_staged_paths
      staged_root.join(work.folder).join("metadata.json")
    else
      staged_root.join("by_work_id", format("%06d", work.work_id), "metadata.json")
    end
  end

  def contained_json_destination(record)
    staged_root.join("contained_works", "by_work_id", format("%06d", record.fetch("work_id")), "metadata.json")
  end

  def metadata_destination_for_record(work, record)
    return json_destination(work) if record["work_id"] == work.work_id
    raise ArgumentError, "--apply does not yet support generated contained-work metadata paths" if @apply

    contained_json_destination(record)
  end

  def apply_destination(work)
    if @corpus_root
      @corpus_root.join(work.folder).join("metadata.json").to_s
    else
      File.join(work.folder, "metadata.json")
    end
  end

  def work_title_for_payload(work, folds, compilation_rule)
    title = folds.dig(:scalars, "title")
    title = nil if source_bucket_generic_title?(work, title)
    title || (compilation_rule && compilation_rule["title"]) || folder_title(work.folder)
  end

  def source_bucket_generic_title?(work, title)
    return false unless title
    root = work.folder.to_s.split("/").first
    source_bucket_roots.include?(root) && title.to_s.strip == root
  end

  def build_payload(work)
    folds = work_folds(work)
    geography = folds.fetch(:geography)
    compilation_rule = compilation_rule_for(work)
    worklist = compilation_rule ? compilation_worklist(work, folds, compilation_rule) : []
    docs = compilation_rule ? [] : work.documents.map { |doc| build_document(doc, folds) }
    base_categories = Array(folds.dig(:lists, "categories"))
    rule_categories = compilation_rule ? Array(compilation_rule["categories"]) : []

    payload = {
      "schema_version" => @key_map.fetch("schema_version", 1),
      "work_id" => work.work_id,
      "corpus_root" => geography["corpus_root"] || corpus_root_for_path(work.folder),
      "macro_region" => geography["macro_region"] || macro_region_for_root(corpus_root_for_path(work.folder)),
      "period" => geography["period"],
      "polity" => geography["polity"],
      "region" => geography["region"],
      "title" => work_title_for_payload(work, folds, compilation_rule),
      "work_base_title" => folds.dig(:scalars, "work_base_title"),
      "date_label" => folds.dig(:scalars, "date_label"),
      "authors" => folds.dig(:lists, "authors"),
      "editors" => folds.dig(:lists, "editors"),
      "contributors" => folds.fetch(:contributors),
      "categories" => uniq_list(base_categories + rule_categories),
      "source_categories" => folds.dig(:lists, "source_categories"),
      "sources" => folds.dig(:lists, "sources"),
      "identifiers" => folds.fetch(:identifiers),
      "rights" => compact_hash({
        "license" => folds.dig(:scalars, "rights.license"),
        "note" => folds.dig(:scalars, "rights.note")
      }),
      "edition" => folds.dig(:scalars, "edition"),
      "medium" => folds.dig(:scalars, "medium"),
      "location" => folds.dig(:scalars, "location"),
      "images" => folds.dig(:lists, "images"),
      "mode" => folds.dig(:scalars, "mode"),
      "mother" => folds.dig(:scalars, "mother"),
      "name" => folds.dig(:scalars, "name"),
      "aliases" => folds.dig(:lists, "aliases"),
      "notes" => folds.dig(:lists, "notes"),
      "credits" => folds.dig(:lists, "credits"),
      "is_compilation" => compilation_rule ? true : (@key_map.dig("defaults", "is_compilation") == true),
      "known_commentaries" => compilation_rule && compilation_rule["known_commentaries"] ? Array(compilation_rule["known_commentaries"]) : Array(@key_map.dig("defaults", "known_commentaries")),
      "contained_in" => Array(@key_map.dig("defaults", "contained_in")),
      "worklist" => worklist,
      "documents" => docs
    }
    payload = deep_compact(payload)
    payload["known_commentaries"] ||= []
    payload["worklist"] ||= [] if payload["is_compilation"]
    payload.delete("documents") if payload["is_compilation"]
    payload
  end

  def build_document(doc, folds)
    work_geography = folds.fetch(:geography)
    document_geography = suppress_work_geography(raw_doc_geography(doc), work_geography)

    deep_compact({
      "document_id" => doc.document_id,
      "file" => doc.file_name,
      "path" => doc.path,
      "title" => doc_scalar(doc, "title", folds.dig(:scalars, "title")),
      "page_title" => doc_scalar(doc, "page_title", folds.dig(:scalars, "page_title")),
      "display_title" => doc_scalar(doc, "display_title", folds.dig(:scalars, "display_title")),
      "chapter" => doc_scalar(doc, "chapter", folds.dig(:scalars, "chapter")),
      "date_label" => doc_scalar(doc, "date_label", folds.dig(:scalars, "date_label")),
      "scraped_at" => doc_scalar(doc, "scraped_at", folds.dig(:scalars, "scraped_at")),
      "authors" => doc_list(doc, "authors", folds.dig(:lists, "authors")),
      "editors" => doc_list(doc, "editors", folds.dig(:lists, "editors")),
      "categories" => doc_list(doc, "categories", folds.dig(:lists, "categories")),
      "source_categories" => doc_list(doc, "source_categories", folds.dig(:lists, "source_categories")),
      "sources" => doc_list(doc, "sources", folds.dig(:lists, "sources")),
      "rights" => compact_hash({
        "license" => doc_scalar(doc, "rights.license", folds.dig(:scalars, "rights.license")),
        "note" => doc_scalar(doc, "rights.note", folds.dig(:scalars, "rights.note"))
      }),
      "edition" => doc_scalar(doc, "edition", folds.dig(:scalars, "edition")),
      "medium" => doc_scalar(doc, "medium", folds.dig(:scalars, "medium")),
      "location" => doc_scalar(doc, "location", folds.dig(:scalars, "location")),
      "images" => doc_list(doc, "images", folds.dig(:lists, "images")),
      "mode" => doc_scalar(doc, "mode", folds.dig(:scalars, "mode")),
      "mother" => doc_scalar(doc, "mother", folds.dig(:scalars, "mother")),
      "name" => doc_scalar(doc, "name", folds.dig(:scalars, "name")),
      "aliases" => doc_list(doc, "aliases", folds.dig(:lists, "aliases")),
      "notes" => doc_list(doc, "notes", folds.dig(:lists, "notes")),
      "credits" => doc_list(doc, "credits", folds.dig(:lists, "credits")),
      "identifiers" => uniq_hashes(doc.identifiers),
      "contributors" => suppress_work_hashes(uniq_hashes(doc.contributors), folds.fetch(:contributors)),
      "contained_in" => dedupe_contained_in(doc.contained_in + compilation_containers_for_path(doc.path)),
      "external_refs" => doc.external_refs,
      "geography_override" => document_geography.empty? ? nil : document_geography,
      "body_start_line" => doc.body_start_line.positive? ? doc.body_start_line : nil
    })
  end

  def work_folds(work)
    @work_fold_cache[work.folder] ||= begin
      scalars = {}
      scalar_targets.each do |key|
        value = folded_work_scalar(work, key)
        scalars[key] = value if value
      end

      lists = {}
      list_targets.each do |key|
        values = folded_work_list(work, key)
        lists[key] = values if values.any?
      end

      {
        scalars: scalars,
        lists: lists,
        contributors: folded_work_hash_list(work, :contributors),
        identifiers: folded_work_hash_list(work, :identifiers),
        geography: folded_geography(work)
      }
    end
  end

  def scalar_targets
    @scalar_targets ||= @key_map.fetch("keys", {}).values.select { |rule| rule["type"] == "scalar" }.map { |rule| rule["target"].to_s }.uniq
  end

  def list_targets
    @list_targets ||= @key_map.fetch("keys", {}).values.select { |rule| rule["type"] == "list" }.map { |rule| rule["target"].to_s }.uniq
  end

  def folded_work_scalar(work, key)
    doc_sets = work.documents.map { |doc| uniq_list(doc.values[key]) }.reject(&:empty?)
    return nil if doc_sets.empty?

    values = doc_sets.flatten.uniq
    if values.length == 1 && liftable_work_value?(work, key, doc_sets.length, work.documents.length)
      return values.first
    end

    action = values.length == 1 ? "kept_document_level_partial_metadata" : "kept_document_level"
    record_fold_decision(work, key, action, "scalar", values.length, doc_sets.length, work.documents.length, values.first(20))
    nil
  end

  def folded_work_list(work, key)
    doc_sets = work.documents.map { |doc| uniq_list(doc.lists[key]).sort }.reject(&:empty?)
    return [] if doc_sets.empty?

    unique_sets = doc_sets.uniq
    if unique_sets.length == 1 && liftable_work_value?(work, key, doc_sets.length, work.documents.length)
      return unique_sets.first
    end

    values = unique_sets.flatten.uniq
    action = unique_sets.length == 1 ? "kept_document_level_partial_metadata" : "kept_document_level"
    record_fold_decision(work, key, action, "list", values.length, doc_sets.length, work.documents.length, values.first(20))
    []
  end

  def folded_work_hash_list(work, attr_name)
    doc_sets = work.documents.map { |doc| uniq_hashes(doc.public_send(attr_name)).sort_by(&:to_s) }.reject(&:empty?)
    return [] if doc_sets.empty?

    unique_sets = doc_sets.uniq
    if unique_sets.length == 1 && liftable_work_value?(work, attr_name.to_s, doc_sets.length, work.documents.length)
      return unique_sets.first
    end

    action = unique_sets.length == 1 ? "kept_document_level_partial_metadata" : "kept_document_level"
    record_fold_decision(work, attr_name.to_s, action, "hash_list", unique_sets.length, doc_sets.length, work.documents.length, unique_sets.first(20).map(&:to_s))
    []
  end

  def liftable_work_value?(_work, _target, covered_documents, total_documents)
    # Strict by default: a legacy field is work-level only when every txt in
    # the folder carries the same value. This avoids turning one item inside
    # 永樂大典/四庫全書/etc. into the folder's work-level title or author.
    covered_documents == total_documents
  end

  def record_fold_decision(work, target, action, value_type, distinct_count, covered_documents, total_documents, sample_values)
    work_folder = work.respond_to?(:folder) ? work.folder : work.to_s
    key = [work_folder, target, action, value_type]
    @fold_decision_keys ||= Set.new
    return if @fold_decision_keys.include?(key)

    @fold_decision_keys << key
    @fold_decisions << {
      work_folder: work_folder,
      target: target,
      action: action,
      value_type: value_type,
      distinct_values: distinct_count,
      covered_documents: covered_documents,
      total_documents: total_documents,
      sample_values: Array(sample_values).first(20).map { |sample| truncate_sample(sample) }.join(" | ")
    }
    @fold_decision_counts_by_work[work_folder] += 1
  end


  def compilation_rule_for(work)
    @compilation_rule_cache[work.folder] ||= begin
      Array(@compilation_map["known_compilations"]).find { |rule| compilation_rule_matches?(rule, work.folder) }
    end
  end

  def compilation_rule_matches?(rule, folder)
    match = rule.fetch("match", {}) || {}
    path = folder.to_s
    parts = path.split("/")
    Array(match["path_contains"]).any? { |needle| path.include?(needle.to_s) } ||
      Array(match["folder_name"]).any? { |name| parts.include?(name.to_s) } ||
      Array(match["folder_basename"]).any? { |name| folder_title(path) == name.to_s }
  end

  def compilation_containers_for_path(path)
    @compilation_containers_cache[path] ||= begin
      parts = path.to_s.split("/")
      Array(@compilation_map["known_compilations"]).filter_map do |rule|
        title = rule["title"].to_s
        next if title.empty?
        next unless compilation_path_matches_rule?(rule, path, parts)

        compact_hash({
          "title" => title,
          "relation" => "contained_in",
          "source" => "compilation_map"
        })
      end
    end
  end

  def compilation_path_matches_rule?(rule, path, parts)
    match = rule.fetch("match", {}) || {}
    Array(match["path_contains"]).any? { |needle| path.to_s.include?(needle.to_s) } ||
      Array(match["folder_name"]).any? { |name| parts.include?(name.to_s) } ||
      Array(match["folder_basename"]).any? { |name| parts.include?(name.to_s) }
  end

  def compilation_title_candidates_for_doc(doc, work_value)
    candidates = compilation_containers_for_path(doc.path).map { |entry| entry["title"] }
    candidates << work_value
    candidates << folder_title(doc.parent_folder)
    candidates.concat(doc.values["work_base_title"] || [])
    candidates.concat(doc.path.to_s.split("/"))
    uniq_list(candidates)
  end

  def resolve_document_title(doc, values, work_value)
    return nil if values.empty?
    return nil if work_value && values.length == 1 && values.first == work_value
    return values.first if values.length == 1

    container_titles = compilation_title_candidates_for_doc(doc, work_value)
    container_values = values.select { |value| container_titles.include?(value) }
    item_values = values.reject { |value| container_values.include?(value) }
    return nil if item_values.empty? && container_values.any? && work_value

    if container_values.any? && item_values.any?
      container_values.each do |title|
        add_contained_in(doc, {
          "title" => title,
          "relation" => "contained_in",
          "source" => "title_conflict"
        })
      end
      record_fold_decision(doc.parent_folder, "title", "title_conflict_as_contained_in", "scalar", values.length, 1, 1, values)
      return item_values.first
    end

    :unresolved
  end

  def add_contained_in(doc, entry)
    clean = compact_hash(entry)
    doc.contained_in << clean unless doc.contained_in.include?(clean)
  end

  def dedupe_contained_in(entries)
    seen = Set.new
    Array(entries).each_with_object([]) do |entry, output|
      clean = compact_hash(entry)
      key = [clean["title"], clean["relation"]]
      next if seen.include?(key)

      seen << key
      output << clean
    end
  end

  def compilation_worklist(work, folds, rule)
    @contained_work_payloads_by_work_id[work.work_id] = []
    return [] unless rule["extractable_items"] != false

    groups = grouped_contained_work_candidates(work, folds, rule)
    groups.map do |_key, group|
      title = group.fetch(:title)
      docs = group.fetch(:documents)
      first_doc = docs.first
      contained_work_id = registry_id(
        "work",
        contained_work_identity_key(work, title),
        path: work.folder,
        title: title,
        parent_work_id: work.work_id,
        source_document_id: first_doc.document_id,
        status: "contained"
      )
      edition_id = registry_id(
        "edition",
        edition_identity_key(work, title),
        path: work.folder,
        title: edition_label_for(rule),
        parent_work_id: contained_work_id,
        source_document_id: first_doc.document_id,
        status: "active"
      )

      geography = proposal_geography_for_group(work, folds, docs)
      proposal = compact_hash({
        contained_work_id: contained_work_id,
        edition_id: edition_id,
        edition_label: edition_label_for(rule),
        compilation_work_id: work.work_id,
        compilation_title: rule["title"],
        source_document_id: first_doc.document_id,
        current_path: first_doc.path,
        title: title,
        document_count: docs.length,
        source_document_ids: docs.map(&:document_id).join("|"),
        source_paths: docs.map(&:path).join("|"),
        current_corpus_root: geography["corpus_root"] || corpus_root_for_path(work.folder),
        current_macro_region: geography["macro_region"] || macro_region_for_root(corpus_root_for_path(work.folder)),
        current_period: geography["period"],
        current_polity: geography["polity"],
        current_region: geography["region"],
        review_note: "generated_contained_work_metadata"
      })
      unless @contained_work_proposal_ids.include?(contained_work_id)
        @contained_work_proposal_ids << contained_work_id
        @contained_work_proposals << proposal
        @proposal_counts_by_work_id[work.work_id] += 1
        @proposal_document_counts_by_work_id[work.work_id] += docs.length
        @contained_work_payloads_by_work_id[work.work_id] << build_contained_work_payload(work, folds, rule, group, contained_work_id, edition_id)
      end

      deep_compact({
        "work_id" => contained_work_id,
        "title" => title,
        "edition_id" => edition_id,
        "edition_label" => edition_label_for(rule)
      })
    end
  end

  def edition_label_for(rule)
    label = rule["edition_label"].to_s.strip
    return label unless label.empty?

    "#{rule.fetch("title")}本"
  end

  def build_contained_work_payload(compilation_work, compilation_folds, rule, group, contained_work_id, edition_id)
    title = group.fetch(:title)
    docs = group.fetch(:documents)
    group_folds = group_folds_for_docs(compilation_work, docs)
    geography = group_folds.fetch(:geography)
    edition_label = edition_label_for(rule)

    deep_compact({
      "schema_version" => @key_map.fetch("schema_version", 1),
      "work_id" => contained_work_id,
      "corpus_root" => geography["corpus_root"] || compilation_folds.fetch(:geography)["corpus_root"] || corpus_root_for_path(compilation_work.folder),
      "macro_region" => geography["macro_region"] || compilation_folds.fetch(:geography)["macro_region"] || macro_region_for_root(corpus_root_for_path(compilation_work.folder)),
      "period" => geography["period"],
      "polity" => geography["polity"],
      "region" => geography["region"],
      "title" => title,
      "date_label" => group_folds.dig(:scalars, "date_label"),
      "authors" => group_folds.dig(:lists, "authors"),
      "editors" => group_folds.dig(:lists, "editors"),
      "contributors" => group_folds.fetch(:contributors),
      "categories" => group_folds.dig(:lists, "categories"),
      "source_categories" => group_folds.dig(:lists, "source_categories"),
      "sources" => group_folds.dig(:lists, "sources"),
      "identifiers" => group_folds.fetch(:identifiers),
      "is_compilation" => false,
      "known_commentaries" => Array(@key_map.dig("defaults", "known_commentaries")),
      "contained_in" => [
        {
          "work_id" => compilation_work.work_id,
          "title" => rule["title"],
          "edition_id" => edition_id,
          "edition_label" => edition_label
        }
      ],
      "editions" => [
        {
          "edition_id" => edition_id,
          "edition_label" => edition_label,
          "source_work_id" => compilation_work.work_id,
          "source_title" => rule["title"],
          "documents" => docs.map { |doc| build_edition_document(doc, compilation_folds, group_folds) }
        }
      ]
    })
  end

  def build_edition_document(doc, compilation_folds, group_folds)
    base = build_document(doc, compilation_folds)
    # Values lifted to the contained-work record do not need to repeat on every
    # edition document.
    base["authors"] = [] if Array(base["authors"]).sort == Array(group_folds.dig(:lists, "authors")).sort
    base["editors"] = [] if Array(base["editors"]).sort == Array(group_folds.dig(:lists, "editors")).sort
    base["contributors"] = [] if Array(base["contributors"]).sort_by(&:to_s) == Array(group_folds.fetch(:contributors)).sort_by(&:to_s)
    base["categories"] = [] if Array(base["categories"]).sort == Array(group_folds.dig(:lists, "categories")).sort
    base["source_categories"] = [] if Array(base["source_categories"]).sort == Array(group_folds.dig(:lists, "source_categories")).sort
    base["sources"] = [] if Array(base["sources"]).sort == Array(group_folds.dig(:lists, "sources")).sort
    deep_compact(base)
  end

  def group_folds_for_docs(work, docs)
    {
      scalars: group_scalar_folds(work, docs),
      lists: group_list_folds(work, docs),
      contributors: group_hash_folds(work, docs, :contributors),
      identifiers: group_hash_folds(work, docs, :identifiers),
      geography: group_geography_folds(work, docs)
    }
  end

  def group_scalar_folds(work, docs)
    scalar_targets.each_with_object({}) do |key, out|
      next if %w[title page_title display_title chapter scraped_at].include?(key)
      values_by_doc = docs.map { |doc| uniq_list(doc.values[key]) }
      covered = values_by_doc.reject(&:empty?)
      next unless covered.length == docs.length

      values = covered.flatten.uniq
      out[key] = values.first if values.length == 1
    end
  end

  def group_list_folds(work, docs)
    list_targets.each_with_object({}) do |key, out|
      next if %w[images].include?(key)
      values_by_doc = docs.map { |doc| uniq_list(doc.lists[key]).sort }
      covered = values_by_doc.reject(&:empty?)
      next unless covered.length == docs.length

      unique_sets = covered.uniq
      out[key] = unique_sets.first if unique_sets.length == 1 && unique_sets.first.any?
    end
  end

  def group_hash_folds(work, docs, field)
    values_by_doc = docs.map { |doc| uniq_hashes(doc.public_send(field)) }
    covered = values_by_doc.reject(&:empty?)
    return [] unless covered.length == docs.length

    values = uniq_hashes(covered.flatten)
    values.any? ? values : []
  end

  def group_geography_folds(work, docs)
    doc_geographies = docs.map { |doc| raw_doc_geography(doc) }.reject(&:empty?)
    output = {}
    %w[corpus_root macro_region period polity region].each do |field|
      values = doc_geographies.map { |geo| geo[field] }.compact.reject(&:empty?).uniq
      output[field] = values.first if values.length == 1 && doc_geographies.length == docs.length
    end
    output
  end

  def grouped_contained_work_candidates(work, folds, rule)
    groups = {}
    skipped = Hash.new(0)

    work.documents.each do |doc|
      candidate = contained_work_candidate_for_doc(work, doc, folds, rule)
      unless candidate
        skipped["no_extractable_title"] += 1
        next
      end

      key = normalise_contained_work_title(candidate.fetch(:title))
      next if key.empty?

      groups[key] ||= { title: key, documents: [] }
      groups[key][:documents] << doc
    end

    if skipped["no_extractable_title"].positive?
      record_fold_decision(
        work,
        "worklist",
        "skipped_container_or_juan_documents",
        "compilation_worklist",
        skipped["no_extractable_title"],
        skipped["no_extractable_title"],
        work.documents.length,
        ["#{skipped['no_extractable_title']} source documents had only container/juan titles"]
      )
    end

    groups.sort_by { |title, _group| title }.to_h
  end

  def contained_work_candidate_for_doc(work, doc, folds, rule)
    work_title = folds.dig(:scalars, "title") || rule["title"] || folder_title(work.folder)
    candidates = []

    Array(doc.values["display_title"]).each { |value| candidates << [value, "display_title"] }
    Array(doc.values["title"]).each { |value| candidates << [value, "title"] }
    Array(doc.values["work_base_title"]).each { |value| candidates << [value, "work_base_title"] }
    Array(doc.values["page_title"]).each { |value| candidates << [contained_title_from_page_title(value), "page_title"] }

    parent_title = folder_title(File.dirname(doc.path.to_s))
    candidates << [parent_title, "parent_folder"]
    candidates << [file_title(doc.file_name), "file_title"]

    candidates.each do |raw_title, source|
      title = normalise_contained_work_title(raw_title)
      next if title.empty?
      next if container_or_volume_title?(title, rule, work_title, source)

      return { title: title, source: source }
    end

    nil
  end

  def contained_title_from_page_title(value)
    text = value.to_s.strip
    return nil if text.empty?

    text.split("/").last
  end

  def normalise_contained_work_title(value)
    text = value.to_s.strip
    return "" if text.empty?

    text = text.gsub(/\s*[（(]四庫全書本[）)]\s*\z/, "")
    text = text.gsub(/\s*[（(]欽定四庫全書本[）)]\s*\z/, "")
    text = text.gsub(/\s*[（(]文淵閣四庫全書本[）)]\s*\z/, "")
    text = text.gsub(/\s*[（(]摛藻堂四庫全書薈要本[）)]\s*\z/, "")
    text.strip
  end

  def container_or_volume_title?(title, rule, work_title, source)
    compilation_title = rule["title"].to_s.strip
    return true if title.empty?
    return true if [compilation_title, work_title.to_s.strip].include?(title)
    return true if %w[clean raw].include?(title)
    return true if title.match?(/\A(?:卷|第)[一二三四五六七八九十百千零〇\d]+(?:卷)?\z/)
    return true if title.match?(/\Ajuan[_\-]?\d+\z/i)

    escaped = Regexp.escape(compilation_title)
    return true if !escaped.empty? && title.match?(/\A#{escaped}(?:__juan[_\-]?\d+|[_\-]?juan[_\-]?\d+|\/卷\d+|卷\d+)\z/i)
    return true if source == "file_title" && title.match?(/__juan[_\-]?\d+\z/i)

    false
  end

  def proposal_geography_for_group(work, folds, docs)
    doc_geographies = docs.map { |doc| raw_doc_geography(doc) }.reject(&:empty?)
    return folds.fetch(:geography) if doc_geographies.empty?

    output = {}
    %w[corpus_root macro_region period polity region].each do |field|
      values = doc_geographies.map { |geo| geo[field] }.compact.reject(&:empty?).uniq
      output[field] = values.first if values.length == 1
    end
    output.empty? ? folds.fetch(:geography) : output
  end

  def doc_scalar(doc, key, work_value = nil)
    values = uniq_list(doc.values[key])
    if key == "title"
      resolved = resolve_document_title(doc, values, work_value)
      return resolved unless resolved == :unresolved
    end

    return nil if values.empty?
    return nil if work_value && values.length == 1 && values.first == work_value
    return values.first if values.length == 1

    record_conflict(
      work_folder: doc.parent_folder,
      path: doc.path,
      target: key,
      conflict_type: "document_scalar_conflict",
      values: values.first(20).join(" | ")
    )
    most_common(values)
  end

  def record_conflict(row)
    @conflict_keys ||= Set.new
    key = [row[:work_folder], row[:path], row[:target], row[:conflict_type], row[:values]]
    return if @conflict_keys.include?(key)

    @conflict_keys << key
    @conflicts << row
    @conflict_counts_by_work[row[:work_folder]] += 1
  end

  def doc_list(doc, key, work_values = nil)
    values = uniq_list(doc.lists[key])
    return [] if values.empty?
    return [] if work_values && values.sort == Array(work_values).sort

    values
  end

  def suppress_work_hashes(doc_values, work_values)
    return [] if doc_values.empty?
    return [] if doc_values == Array(work_values)

    doc_values
  end

  def folded_geography(work)
    doc_geographies = work.documents.map { |doc| raw_doc_geography(doc) }.reject(&:empty?)
    output = {}

    %w[corpus_root macro_region period polity region].each do |field|
      covered = doc_geographies.select { |geo| geo[field].to_s.strip != "" }
      values = covered.map { |geo| geo[field] }.uniq
      next if values.empty?

      if values.length == 1 && covered.length == work.documents.length
        output[field] = values.first
      else
        action = values.length == 1 ? "kept_document_level_partial_geography" : "kept_document_level"
        record_fold_decision(work, field, action, "geography", values.length, covered.length, work.documents.length, values.first(20))
      end
    end

    output
  end

  def raw_doc_geography(doc)
    fold_hash_values(doc.geography_values, doc.parent_folder, doc.path)
  end

  def suppress_work_geography(doc_geography, work_geography)
    doc_geography.reject do |field, value|
      work_geography[field] == value
    end
  end

  def fold_hash_values(rows, folder, path)
    output = {}
    %w[corpus_root macro_region period polity region].each do |field|
      candidates = rows.filter_map do |row|
        value = row[field]
        next if value.to_s.strip.empty?

        [value, geography_priority(row["raw_key"], field)]
      end
      next if candidates.empty?

      max_priority = candidates.map(&:last).max
      values = candidates.select { |_value, priority| priority == max_priority }.map(&:first).uniq
      if values.length == 1
        output[field] = values.first
      else
        record_conflict(
          work_folder: folder,
          path: path,
          target: field,
          conflict_type: "document_geography_conflict",
          values: values.first(20).join(" | ")
        )
        output[field] = values.first
      end
    end
    output
  end

  def geography_priority(raw_key, field)
    case field
    when "corpus_root", "macro_region"
      { "NATION" => 30, "TIMES" => 20, "REGION" => 10 }.fetch(raw_key.to_s, 0)
    when "period", "polity"
      { "TIMES" => 30, "REGION" => 20, "NATION" => 10 }.fetch(raw_key.to_s, 0)
    else
      { "REGION" => 30, "TIMES" => 20, "NATION" => 10 }.fetch(raw_key.to_s, 0)
    end
  end

  def work_warnings(work)
    warnings = []
    warnings << "unknown_legacy_keys_present" if work.unknown_rows.any?
    warnings << "ignored_bad_parse_rows_present" if work.ignored_rows.any?
    warnings << "heterogeneous_metadata_kept_document_level" if @fold_decision_counts_by_work[work.folder].positive?
    warnings
  end

  def corpus_root_for_path(path)
    path.to_s.split("/").first
  end

  def macro_region_for_root(root)
    @geography_map.dig("corpus_roots", root, "macro_region")
  end

  def folder_title(folder)
    File.basename(folder.to_s)
  end

  def file_title(file_name)
    File.basename(file_name.to_s, File.extname(file_name.to_s))
  end

  def write_reports!
    write_work_manifest
    write_document_manifest
    write_conflicts
    write_fold_decisions
    write_contained_work_proposals
    write_id_registry
    write_issues("ignored_legacy_rows.csv", @ignored_rows)
    write_issues("unknown_legacy_rows.csv", @unknown_rows)
    write_summary
    write_report_md
  end

  def write_work_manifest
    headers = %w[work_id folder json_path apply_destination documents title is_compilation worklist_items worklist_documents corpus_root macro_region period polity region conflicts fold_decisions unknown_rows ignored_rows]
    CSV.open(@output_root.join("work_manifest.csv"), "w", write_headers: true, headers: headers) do |csv|
      @works.keys.sort.each do |folder|
        work = @works.fetch(folder)
        folds = work_folds(work)
        geography = folds.fetch(:geography)
        compilation_rule = compilation_rule_for(work)
        csv << [
          work.work_id,
          folder,
          json_destination(work).to_s,
          apply_destination(work),
          work.documents.length,
          work_title_for_payload(work, folds, compilation_rule),
          compilation_rule ? true : false,
          @proposal_counts_by_work_id[work.work_id],
          @proposal_document_counts_by_work_id[work.work_id],
          geography["corpus_root"] || corpus_root_for_path(folder),
          geography["macro_region"] || macro_region_for_root(corpus_root_for_path(folder)),
          geography["period"],
          geography["polity"],
          geography["region"],
          @conflict_counts_by_work[folder],
          @fold_decision_counts_by_work[folder],
          work.unknown_rows.length,
          work.ignored_rows.length
        ]
      end
    end
  end

  def write_document_manifest
    headers = %w[document_id work_id path file title page_title chapter date_label body_start_line]
    CSV.open(@output_root.join("document_manifest.csv"), "w", write_headers: true, headers: headers) do |csv|
      @works.keys.sort.each do |folder|
        work = @works.fetch(folder)
        folds = work_folds(work)
        work.documents.each do |doc|
          csv << [
            doc.document_id,
            work.work_id,
            doc.path,
            doc.file_name,
            doc_scalar(doc, "title", folds.dig(:scalars, "title")),
            doc_scalar(doc, "page_title", folds.dig(:scalars, "page_title")),
            doc_scalar(doc, "chapter", folds.dig(:scalars, "chapter")),
            doc_scalar(doc, "date_label", folds.dig(:scalars, "date_label")),
            doc.body_start_line
          ]
        end
      end
    end
  end

  def write_conflicts
    headers = %w[work_folder path target conflict_type values]
    CSV.open(@output_root.join("metadata_conflicts.csv"), "w", write_headers: true, headers: headers) do |csv|
      @conflicts.each { |row| csv << headers.map { |key| row[key.to_sym] } }
    end
  end

  def write_fold_decisions
    headers = %w[work_folder target action value_type distinct_values covered_documents total_documents sample_values]
    CSV.open(@output_root.join("metadata_fold_decisions.csv"), "w", write_headers: true, headers: headers) do |csv|
      @fold_decisions.each { |row| csv << headers.map { |key| row[key.to_sym] } }
    end
  end

  def write_contained_work_proposals
    headers = %w[contained_work_id edition_id edition_label compilation_work_id compilation_title title document_count source_document_id current_path source_document_ids source_paths current_corpus_root current_macro_region current_period current_polity current_region review_note]
    CSV.open(@output_root.join("contained_work_proposals.csv"), "w", write_headers: true, headers: headers) do |csv|
      @contained_work_proposals.sort_by { |row| [row[:compilation_title].to_s, row[:title].to_s] }.each do |row|
        csv << headers.map { |key| row[key.to_sym] }
      end
    end
  end

  def write_id_registry
    headers = %w[kind id identity_key path title parent_work_id source_document_id status]
    CSV.open(@id_registry_output_path, "w", write_headers: true, headers: headers) do |csv|
      @id_registry_rows.sort_by { |row| [row[:kind].to_s, row[:id].to_i] }.each do |row|
        csv << headers.map { |key| row[key.to_sym] }
      end
    end
  end

  def write_issues(file_name, rows)
    headers = %w[work_folder path line_number raw_key canonical_key value reason]
    CSV.open(@output_root.join(file_name), "w", write_headers: true, headers: headers) do |csv|
      rows.each { |row| csv << headers.map { |key| row[key.to_sym] } }
    end
  end

  def write_summary
    payload = {
      version: 2,
      mode: @apply ? "apply" : "dry_run",
      staged_path_mode: @apply ? "apply" : @json_output_mode,
      source_mode: @source_mode,
      started_at: @started_at.iso8601,
      finished_at: Time.now.utc.iso8601,
      audit_output: @audit_output.to_s,
      output_root: @output_root.to_s,
      works: @works.length,
      documents: @docs_by_path.length,
      metadata_records_written: @metadata_records_written,
      conflicts: @conflicts.length,
      fold_decisions: @fold_decisions.length,
      contained_work_proposals: @contained_work_proposals.length,
      ignored_legacy_rows: @ignored_rows.length,
      unknown_legacy_rows: @unknown_rows.length,
      staged_root: staged_root.to_s,
      staged_jsonl: write_staged_jsonl? ? jsonl_path.to_s : nil
    }
    @output_root.join("json_generation_summary.json").write(JSON.pretty_generate(payload) + "\n")
  end

  def write_report_md
    text = <<~MD
      # JSON metadata dry-run report

      - Mode: `#{@apply ? "apply" : "dry_run"}`
      - Staged path mode: `#{@apply ? "apply" : @json_output_mode}`
      - Source mode: `#{@source_mode}`
      - Works/folders: #{@works.length}
      - Documents/txt files: #{@docs_by_path.length}
      - Metadata records written: #{@metadata_records_written}
      - Conflicts: #{@conflicts.length}
      - Fold decisions: #{@fold_decisions.length}
      - Contained work proposals: #{@contained_work_proposals.length}
      - Ignored bad/legacy rows: #{@ignored_rows.length}
      - Unknown legacy rows: #{@unknown_rows.length}

      Output files:

      - `staged_metadata.jsonl`: generated review metadata as one JSON object per line. This is the default because 176k tiny files are very slow on WSL/OneDrive.
      - `staged_metadata/by_work_id/<work_id>/metadata.json`: generated only with `--json-output-mode files` or `--json-output-mode both`.
      - `work_manifest.csv`: one row per work folder, including real apply destination.
      - `document_manifest.csv`: one row per txt file.
      - `metadata_conflicts.csv`: genuine document-level scalar/geography conflicts to review before apply.
      - `metadata_fold_decisions.csv`: cases where heterogeneous metadata was kept at document level instead of lifted to work level.
      - `contained_work_proposals.csv`: grouped compilation-contained works emitted as separate staged metadata records. Juan/container files are skipped, and multiple source documents for the same contained work are grouped into one edition witness.
      - `metadata_id_registry.csv`: generated/reused IDs for work, document, and edition records. Pass it back with `--id-registry` on future runs to preserve IDs.
      - `ignored_legacy_rows.csv`: known bad parse rows deliberately excluded.
      - `unknown_legacy_rows.csv`: legacy keys not yet mapped.
      - `json_generation_summary.json`: machine-readable run summary.

      Source-mode rule:

      - Default `--source-mode clean` excludes paths under any `raw/` segment.
      - Use `--source-mode all` only when you deliberately want raw and clean source material in the same review run.
      - Use `--source-mode raw` only for inspecting deprecated raw material.
      - Source buckets such as `維基大典` and `礦藝大典` are split into page-level work records instead of fake `clean`/`raw` bucket works.

      Fold-up rule:

      - A value is lifted to work level only when every document in that folder carries the same value.
      - If values disagree, or if only some documents carry the value, they remain on individual `documents[]` entries.
      - Document geography identical to work geography is suppressed to avoid duplicate noise.

      This script is designed for review. Do not apply generated JSON to the corpus until
      conflicts and unknown legacy keys are acceptable.
    MD
    @output_root.join("JSON_GENERATION_REPORT.md").write(text)
  end

  def truncate_sample(value)
    text = value.to_s
    text.length > 300 ? "#{text[0, 300]}…" : text
  end

  def uniq_list(values)
    Array(values).flatten.compact.map(&:to_s).map(&:strip).reject(&:empty?).uniq
  end

  def uniq_hashes(values)
    Array(values).compact.map { |value| value.is_a?(Hash) ? value : { "value" => value.to_s } }.uniq
  end

  def most_common(values)
    values.group_by(&:itself).max_by { |_value, group| group.length }&.first
  end

  def presence(value)
    value.to_s.strip.empty? ? nil : value.to_s.strip
  end

  def compact_hash(hash)
    hash.reject { |_key, value| value.nil? || value == [] || value == {} || value == "" }
  end

  def deep_compact(value)
    case value
    when Hash
      compact_hash(value.transform_values { |child| deep_compact(child) })
    when Array
      value.map { |child| deep_compact(child) }.reject { |child| child.nil? || child == [] || child == {} || child == "" }
    else
      value
    end
  end
end

options = {
  key_map: CorpusMetadataJsonDryRun::DEFAULT_KEY_MAP,
  geography_map: CorpusMetadataJsonDryRun::DEFAULT_GEOGRAPHY_MAP,
  compilation_map: CorpusMetadataJsonDryRun::DEFAULT_COMPILATION_MAP,
  apply: false,
  mirror_staged_paths: false,
  json_output_mode: "jsonl",
  source_mode: "clean",
  progress_every: 25_000,
  work_id_start: 1,
  document_id_start: 1,
  edition_id_start: 1
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby script/corpus_metadata_json_dry_run.rb --audit-output DIR --output DIR [options]"
  opts.on("--audit-output DIR", "Directory produced by corpus_metadata_audit.rb") { |value| options[:audit_output] = value }
  opts.on("--geography-suggestions CSV", "geography_mapping_suggestions.csv from the geography mapping script") { |value| options[:geography_suggestions] = value }
  opts.on("--key-map PATH", "JSON generation key map YAML") { |value| options[:key_map] = value }
  opts.on("--geography-map PATH", "Geography seed map YAML") { |value| options[:geography_map] = value }
  opts.on("--compilation-map PATH", "Known compilation/collection map YAML") { |value| options[:compilation_map] = value }
  opts.on("--id-registry PATH", "Existing metadata_id_registry.csv to reuse stable IDs") { |value| options[:id_registry] = value }
  opts.on("--write-id-registry PATH", "Where to write the updated ID registry; defaults to OUTPUT/metadata_id_registry.csv") { |value| options[:write_id_registry] = value }
  opts.on("--output DIR", "Output directory") { |value| options[:output] = value }
  opts.on("--corpus-root DIR", "Corpus root; required only with --apply") { |value| options[:corpus_root] = value }
  opts.on("--apply", "Write metadata.json into the corpus instead of staged_metadata (dangerous; review first)") { options[:apply] = true }
  opts.on("--mirror-staged-paths", "With --json-output-mode files/both, mirror corpus paths instead of short by_work_id paths") { options[:mirror_staged_paths] = true }
  opts.on("--json-output-mode MODE", "Dry-run output mode: jsonl, files, or both. Default: jsonl") { |value| options[:json_output_mode] = value }
  opts.on("--source-mode MODE", "Source mode: clean, all, or raw. Default: clean; clean excludes raw/ paths") { |value| options[:source_mode] = value }
  opts.on("--progress-every N", Integer, "Print progress every N loaded/written rows. Default: 25000; 0 disables") { |value| options[:progress_every] = value }
  opts.on("--max-folders N", Integer, "Smoke-test only the first N folders") { |value| options[:max_folders] = value }
  opts.on("--max-files N", Integer, "Smoke-test only the first N txt files") { |value| options[:max_files] = value }
  opts.on("--work-id-start N", Integer, "First assigned work_id") { |value| options[:work_id_start] = value }
  opts.on("--document-id-start N", Integer, "First assigned document_id") { |value| options[:document_id_start] = value }
  opts.on("--edition-id-start N", Integer, "First assigned edition_id") { |value| options[:edition_id_start] = value }
end

parser.parse!(ARGV)
missing = %i[audit_output output].select { |key| options[key].to_s.empty? }
if missing.any?
  warn parser
  abort "Missing required option(s): #{missing.join(', ')}"
end

CorpusMetadataJsonDryRun.new(options).run
