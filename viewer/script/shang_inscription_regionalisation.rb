#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "find"
require "json"
require "optparse"
require "pathname"
require "set"
require "time"
require "yaml"

# Rebuilds the Shang inscription tree around physical objects rather than
# database sentence rows.
#
# The script is deliberately split into two modes:
#
#   1. Plan (default): read the current tree, write reports and an exact plan.
#   2. Apply: execute one reviewed plan and verify every source file hash.
#
# The script never edits Rails routes and has no Rails dependency.
class ShangInscriptionRegionalisation
  PLAN_VERSION = 2
  REGISTRY_HEADERS = %w[kind id identity_key path title parent_work_id source_document_id status].freeze
  DEFAULT_CONFIG = "config/corpus_metadata/shang_inscription_regionalisation.yml"
  DEFAULT_PROGRESS_EVERY = 1_000

  OracleRecord = Struct.new(
    :series, :locator, :source_label, :metadata_path, :metadata,
    :document, :source_file, :work_id_candidate, :material_type,
    :language_code, keyword_init: true
  )

  ParsedLocator = Struct.new(
    :object_value, :surface, :segment, :normalized_locator, keyword_init: true
  )

  def initialize(options)
    @options = options
    @shang_root = Pathname(utf8_string(options.fetch(:shang_root))).expand_path
    @output = Pathname(utf8_string(options.fetch(:output))).expand_path
    @config_path = Pathname(utf8_string(options.fetch(:config))).expand_path
    @concordance_path = options[:concordances] && Pathname(utf8_string(options[:concordances])).expand_path
    @override_path = options[:overrides] && Pathname(utf8_string(options[:overrides])).expand_path
    @id_registry_path = options[:id_registry] && Pathname(utf8_string(options[:id_registry])).expand_path
    @apply = options.fetch(:apply)
    @reviewed_plan = options[:reviewed_plan] && Pathname(utf8_string(options[:reviewed_plan])).expand_path
    @scope = options.fetch(:scope)
    @progress_every = options.fetch(:progress_every).to_i
    @started_at = Time.now.utc
    @unparsed = []
    @warnings = []
    @next_work_id = nil
    @next_document_id = nil
    @registry_rows = nil
    @registry_headers = nil
    @registry_by_kind_id = nil
    @registry_by_identity = nil
    @registry_max_ids = nil
    @corpus_prefix = nil
  end

  def run
    validate_base_inputs!

    if @apply
      apply_reviewed_plan!
    else
      build_plan!
    end
  end

  private

  # ------------------------------------------------------------------------
  # Common helpers
  # ------------------------------------------------------------------------

  def utf8_string(value)
    string = value.to_s.dup
    string.force_encoding(Encoding::UTF_8)
    raise ArgumentError, "Path is not valid UTF-8: #{value.inspect}" unless string.valid_encoding?

    string
  end

  def progress(message)
    warn "[shang-regionalisation] #{Time.now.utc.iso8601} #{message}"
  end

  def maybe_progress(count, label)
    return unless @progress_every.positive?
    return unless (count % @progress_every).zero?

    progress "#{label}: #{count}"
  end

  def elapsed
    (Time.now.utc - @started_at).round(1)
  end

  def validate_base_inputs!
    raise ArgumentError, "Shang root does not exist: #{@shang_root}" unless @shang_root.directory?
    raise ArgumentError, "Config does not exist: #{@config_path}" unless @config_path.file?
    raise ArgumentError, "Concordance CSV does not exist: #{@concordance_path}" if @concordance_path && !@concordance_path.file?
    raise ArgumentError, "Override CSV does not exist: #{@override_path}" if @override_path && !@override_path.file?
    raise ArgumentError, "--id-registry is required; pass the authoritative metadata_id_registry.csv from the completed JSON migration" unless @id_registry_path
    raise ArgumentError, "ID registry does not exist: #{@id_registry_path}" unless @id_registry_path.file?
    raise ArgumentError, "--scope must be all, oracle_bones, or bronzes" unless %w[all oracle_bones bronzes].include?(@scope)
    raise ArgumentError, "--apply requires --reviewed-plan" if @apply && !@reviewed_plan
  end

  def load_config
    @config ||= YAML.safe_load(@config_path.read(encoding: "UTF-8"), aliases: false) || {}
  rescue Psych::SyntaxError => error
    raise ArgumentError, "Invalid YAML #{@config_path}: #{error.message}"
  end

  def config_sha256
    Digest::SHA256.file(@config_path).hexdigest
  end

  def concordance_sha256
    @concordance_path&.file? ? Digest::SHA256.file(@concordance_path).hexdigest : nil
  end

  def oracle_concordances
    @oracle_concordances ||= begin
      mappings = {}
      if @concordance_path&.file?
        required = %w[series canonical_series canonical_object_value]
        headers = CSV.open(@concordance_path, "r:bom|utf-8", headers: true) do |csv|
          csv.first
          csv.headers || []
        end
        missing = required - headers
        raise ArgumentError, "Concordance CSV is missing columns: #{missing.join(', ')}" if missing.any?
        unless headers.include?("object_value") || headers.include?("locator")
          raise ArgumentError, "Concordance CSV must contain object_value, locator, or both"
        end

        CSV.foreach(@concordance_path, headers: true, encoding: "bom|utf-8") do |row|
          series = row["series"].to_s.strip
          object_value = row["object_value"].to_s.strip.tr("+", "＋")
          locator = row["locator"].to_s.strip.tr("+", "＋")
          canonical_series = row["canonical_series"].to_s.strip
          canonical_object = row["canonical_object_value"].to_s.strip.tr("+", "＋")
          next if series.empty? || canonical_series.empty? || canonical_object.empty?
          if object_value.empty? && locator.empty?
            raise ArgumentError, "Oracle concordance row for #{series} needs object_value or locator"
          end

          match_type = locator.empty? ? "object" : "locator"
          match_value = locator.empty? ? object_value : locator
          key = [match_type, series, match_value]
          raise ArgumentError, "Duplicate oracle concordance for #{match_type} #{series} #{match_value}" if mappings.key?(key)
          mappings[key] = {
            "canonical_series" => canonical_series,
            "canonical_object_value" => canonical_object,
            "source" => row["source"].to_s.strip,
            "note" => row["note"].to_s.strip
          }
        end
      end
      mappings
    end
  end

  def oracle_concordance_for(series, parsed)
    exact = oracle_concordances[["locator", series, parsed.normalized_locator]]
    object = oracle_concordances[["object", series, parsed.object_value]]
    row = exact || object
    return [series, parsed.object_value, nil] unless row

    [row.fetch("canonical_series"), row.fetch("canonical_object_value"), row]
  end

  def override_sha256
    @override_path&.file? ? Digest::SHA256.file(@override_path).hexdigest : nil
  end

  def oracle_overrides
    @oracle_overrides ||= begin
      mappings = {}
      if @override_path&.file?
        required = %w[series object_value]
        headers = CSV.open(@override_path, "r:bom|utf-8", headers: true) do |csv|
          csv.first
          csv.headers || []
        end
        missing = required - headers
        raise ArgumentError, "Override CSV is missing columns: #{missing.join(', ')}" if missing.any?

        CSV.foreach(@override_path, headers: true, encoding: "bom|utf-8") do |row|
          series = row["series"].to_s.strip
          object_value = row["object_value"].to_s.strip.tr("+", "＋")
          next if series.empty? || object_value.empty?

          key = [series, object_value]
          raise ArgumentError, "Duplicate oracle override for #{series} #{object_value}" if mappings.key?(key)
          mappings[key] = row.to_h.transform_values { |value| value.to_s.strip }
        end
      end
      mappings
    end
  end

  def id_registry_sha256
    Digest::SHA256.file(@id_registry_path).hexdigest
  end

  def normalize_registry_path(value)
    value.to_s.strip.tr("\\", "/").sub(%r{\A\./}, "").sub(%r{/+\z}, "")
  end

  def load_id_registry!
    return if @registry_rows

    headers = CSV.open(@id_registry_path, "r:bom|utf-8", headers: true) do |csv|
      csv.first
      csv.headers || []
    end
    missing = REGISTRY_HEADERS - headers
    raise ArgumentError, "ID registry is missing columns: #{missing.join(', ')}" if missing.any?

    rows = []
    by_kind_id = {}
    by_identity = {}
    max_ids = Hash.new(0)

    CSV.foreach(@id_registry_path, headers: true, encoding: "bom|utf-8") do |row|
      payload = headers.to_h { |header| [header, row[header].to_s] }
      kind = payload["kind"].strip
      id = integer_or_nil(payload["id"])
      identity_key = payload["identity_key"].strip
      payload["path"] = normalize_registry_path(payload["path"])
      next if kind.empty? || !id

      id_key = [kind, id]
      if by_kind_id.key?(id_key)
        raise ArgumentError, "Duplicate ID registry row for #{kind} #{id}"
      end
      unless identity_key.empty?
        identity = [kind, identity_key]
        if by_identity.key?(identity)
          raise ArgumentError, "Duplicate ID registry identity #{kind} #{identity_key}"
        end
        by_identity[identity] = payload
      end

      by_kind_id[id_key] = payload
      max_ids[kind] = [max_ids[kind], id].max
      rows << payload
    end

    @registry_headers = headers
    @registry_rows = rows
    @registry_by_kind_id = by_kind_id
    @registry_by_identity = by_identity
    @registry_max_ids = max_ids
  end

  def registry_max_id(kind)
    load_id_registry!
    @registry_max_ids.fetch(kind, 0)
  end

  def registry_full_work_path(shang_relative_folder)
    [@corpus_prefix, "商殷朝", shang_relative_folder].reject(&:empty?).join("/")
  end

  def registry_row(kind:, id:, path:, title:, parent_work_id: nil, source_document_id: nil, status: "active", identity_key: nil, base: nil)
    row = (base || {}).dup
    row["kind"] = kind
    row["id"] = id.to_s
    row["path"] = normalize_registry_path(path)
    row["identity_key"] = identity_key || "#{kind}:#{row['path']}"
    row["title"] = title.to_s
    row["parent_work_id"] = parent_work_id.to_s
    row["source_document_id"] = source_document_id.to_s
    row["status"] = status.to_s
    @registry_headers.each { |header| row[header] = row[header].to_s }
    row
  end

  def sha256(path)
    Digest::SHA256.file(path).hexdigest
  end

  def read_json(path)
    JSON.parse(path.read(encoding: "UTF-8"))
  rescue JSON::ParserError => error
    raise ArgumentError, "Invalid JSON #{path}: #{error.message}"
  end

  def atomic_write_json(path, payload)
    FileUtils.mkdir_p(path.dirname)
    temporary = Pathname("#{path}.tmp-#{Process.pid}")
    temporary.write(JSON.pretty_generate(payload) + "\n", encoding: "UTF-8")
    FileUtils.mv(temporary, path)
  ensure
    FileUtils.rm_f(temporary) if defined?(temporary) && temporary
  end

  def relative_to_shang(path)
    Pathname(path).expand_path.relative_path_from(@shang_root).to_s.tr("\\", "/")
  end

  def absolute_from_shang(relative)
    @shang_root.join(relative.to_s)
  end

  # Some uploaded ZIPs encode a Unicode filename as literal #Uxxxx runs.
  # The real corpus normally uses Unicode. Supporting both makes the audit
  # reproducible against an extracted review archive.
  def decode_hash_u(value)
    # The review ZIP convention used by this project emits one four-digit
    # #Uxxxx token per BMP character. Matching five or six characters greedily
    # can swallow a following hexadecimal digit from an object identifier.
    utf8_string(value).gsub(/#U([0-9a-fA-F]{4})/) { Regexp.last_match(1).to_i(16).chr(Encoding::UTF_8) }
  end

  def child_named(parent, wanted)
    return nil unless parent.directory?

    actual = Dir.children(parent).map { |name| utf8_string(name) }.find { |name| decode_hash_u(name) == wanted }
    actual && parent.join(actual)
  end

  def descendants_named(root, wanted)
    matches = []
    Find.find(root.to_s) do |raw_path|
      path = Pathname(utf8_string(raw_path))
      next unless path.directory?
      matches << path if decode_hash_u(path.basename.to_s) == wanted
    end
    matches
  end

  def deep_compact(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, item), memo|
        compacted = deep_compact(item)
        next if compacted.nil?
        next if compacted.respond_to?(:empty?) && compacted.empty?

        memo[key] = compacted
      end
    when Array
      value.map { |item| deep_compact(item) }.reject do |item|
        item.nil? || (item.respond_to?(:empty?) && item.empty?)
      end
    else
      value
    end
  end

  def unique_array(values)
    seen = Set.new
    Array(values).each_with_object([]) do |value, memo|
      key = value.is_a?(Hash) || value.is_a?(Array) ? JSON.generate(value) : value.to_s
      next if key.empty? || seen.include?(key)

      seen << key
      memo << value
    end
  end

  def integer_or_nil(value)
    integer = Integer(value)
    integer.positive? ? integer : nil
  rescue ArgumentError, TypeError
    nil
  end

  def sanitize_filename(value)
    value.to_s.gsub(/[\\\/:*?"<>|]/, "＿").gsub(/\s+/, " ").strip
  end

  def source_abbreviation(value)
    sanitize_filename(value).gsub(/[^\p{L}\p{N}_-]+/u, "_").sub(/\A_+/, "").sub(/_+\z/, "")
  end

  def infer_corpus_prefix(metadata_rows)
    paths = metadata_rows.flat_map { |row| document_hashes(row) }.map { |doc| doc["path"].to_s }.reject(&:empty?)
    example = paths.find { |path| path.include?("/商殷朝/") }
    return example.split("/商殷朝/", 2).first if example

    configured = load_config.dig("corpus", "corpus_root").to_s
    configured.empty? ? "中國漢文/clean" : "#{configured}/clean"
  end

  def corpus_document_path(shang_relative)
    [@corpus_prefix, "商殷朝", shang_relative].reject(&:empty?).join("/")
  end

  def document_hashes(metadata)
    docs = Array(metadata["documents"])
    docs.concat(Array(metadata["editions"]).flat_map { |edition| Array(edition["documents"]) })
    docs.select { |doc| doc.is_a?(Hash) }
  end

  def registry_document_hashes(metadata)
    docs = document_hashes(metadata)
    docs.concat(Array(metadata["translations"]).flat_map do |translation|
      translation.is_a?(Hash) ? Array(translation["documents"]) : []
    end)
    docs.select { |doc| doc.is_a?(Hash) }.uniq { |doc| integer_or_nil(doc["document_id"]) || doc["path"].to_s }
  end

  def all_metadata_paths
    @all_metadata_paths ||= @shang_root.glob("**/metadata.json").select(&:file?)
  end

  def all_metadata_rows
    @all_metadata_rows ||= all_metadata_paths.map { |path| read_json(path) }
  end

  def max_existing_work_id
    all_metadata_rows.filter_map { |metadata| integer_or_nil(metadata["work_id"]) }.max || 0
  end

  def max_existing_document_id
    all_metadata_rows.flat_map { |metadata| document_hashes(metadata) }
      .filter_map { |document| integer_or_nil(document["document_id"]) }
      .max || 0
  end

  def allocate_work_id
    @next_work_id += 1
  end

  def allocate_document_id
    @next_document_id += 1
  end

  # ------------------------------------------------------------------------
  # Plan generation
  # ------------------------------------------------------------------------

  def build_plan!
    progress "validating current tree"
    FileUtils.mkdir_p(@output)

    progress "loading authoritative global ID registry"
    load_id_registry!
    progress "loaded #{@registry_rows.length} registry rows; max_work_id=#{registry_max_id('work')}; max_document_id=#{registry_max_id('document')}"

    progress "loading metadata sidecars"
    metadata_rows = all_metadata_rows
    @corpus_prefix = infer_corpus_prefix(metadata_rows)
    @next_work_id = [max_existing_work_id, registry_max_id("work")].max
    @next_document_id = [max_existing_document_id, registry_max_id("document")].max
    progress "loaded #{metadata_rows.length} metadata files; allocation_starts_after_work_id=#{@next_work_id}; allocation_starts_after_document_id=#{@next_document_id}; corpus_prefix=#{@corpus_prefix}"

    plan_entries = []
    object_rows = []
    move_rows = []
    alias_rows = []
    extra_moves = []
    obsolete_metadata = Set.new

    if %w[all oracle_bones].include?(@scope)
      progress "scanning oracle-bone records"
      oracle_result = build_oracle_plan
      plan_entries.concat(oracle_result.fetch(:entries))
      object_rows.concat(oracle_result.fetch(:object_rows))
      move_rows.concat(oracle_result.fetch(:move_rows))
      alias_rows.concat(oracle_result.fetch(:alias_rows))
      extra_moves.concat(oracle_result.fetch(:extra_moves, []))
      obsolete_metadata.merge(oracle_result.fetch(:obsolete_metadata))
    end

    if %w[all bronzes].include?(@scope)
      progress "scanning bronze records"
      bronze_result = build_bronze_plan
      plan_entries.concat(bronze_result.fetch(:entries))
      object_rows.concat(bronze_result.fetch(:object_rows))
      move_rows.concat(bronze_result.fetch(:move_rows))
      alias_rows.concat(bronze_result.fetch(:alias_rows))
      obsolete_metadata.merge(bronze_result.fetch(:obsolete_metadata))
    end

    progress "building collection metadata"
    collection_entries = build_collection_entries(plan_entries)
    plan_entries.concat(collection_entries)
    object_rows.concat(collection_entries.map { |entry| plan_entry_csv_row(entry) })
    collection_entries.each do |entry|
      obsolete_metadata.merge(Array(entry["source_metadata_paths"]))
      Array(entry.dig("metadata", "legacy_work_ids")).each do |legacy_id|
        alias_rows << {
          "old_work_id" => legacy_id,
          "new_work_id" => entry["work_id"],
          "status" => "merged_into_collection",
          "target_folder" => entry["target_folder"],
          "title" => entry["title"]
        }
      end
    end

    skeleton = Array(load_config["folder_skeleton"]).map { |parts| Array(parts).join("/") }

    progress "building reviewed global ID-registry update"
    registry_result = build_updated_registry(plan_entries, alias_rows)
    updated_registry_path = @output.join("metadata_id_registry.updated.csv")
    write_registry_csv(updated_registry_path, registry_result.fetch(:rows))
    write_csv(@output.join("id_registry_changes.csv"), registry_result.fetch(:changes))
    updated_registry_sha256 = sha256(updated_registry_path)

    plan = {
      "plan_version" => PLAN_VERSION,
      "generated_at" => Time.now.utc.iso8601,
      "scope" => @scope,
      "config_sha256" => config_sha256,
      "concordance_sha256" => concordance_sha256,
      "override_sha256" => override_sha256,
      "id_registry_sha256" => id_registry_sha256,
      "id_registry_path_hint" => @id_registry_path.to_s,
      "updated_id_registry_file" => updated_registry_path.basename.to_s,
      "updated_id_registry_sha256" => updated_registry_sha256,
      "registry_changes" => registry_result.fetch(:summary),
      "corpus_prefix" => @corpus_prefix,
      "folder_skeleton" => skeleton,
      "entries" => plan_entries.sort_by { |entry| [entry["kind"].to_s, entry["target_folder"].to_s] },
      "extra_moves" => extra_moves.sort_by { |move| move["target"].to_s },
      "obsolete_metadata" => obsolete_metadata.to_a.sort,
      "unparsed_count" => @unparsed.length,
      "warning_count" => @warnings.length
    }

    move_rows.concat(extra_moves.map { |move| extra_move_csv_row(move) })
    write_plan_outputs(plan, object_rows, move_rows, alias_rows)

    if @unparsed.any?
      warn "[shang-regionalisation] IMPORTANT: #{@unparsed.length} records were not parsed. Apply will remain blocked until they are handled."
    end

    progress "finished plan: entries=#{plan_entries.length} moves=#{move_rows.length} registry_changes=#{registry_result.fetch(:changes).length} unparsed=#{@unparsed.length} warnings=#{@warnings.length} elapsed=#{elapsed}s"
    warn "[shang-regionalisation] Review #{@output.join('REGIONALISATION_REPORT.md')} and the CSV files."
  end

  def build_oracle_plan
    rules = load_config.fetch("oracle_series")
    source_labels = load_config.fetch("source_labels", {})
    records = []
    support_records = []
    obsolete_metadata = Set.new

    oracle_root = child_named(@shang_root, "甲骨")
    if oracle_root
      count = 0
      oracle_root.glob("**/metadata.json").each do |metadata_path|
        next if metadata_path == oracle_root.join("metadata.json")

        metadata = read_json(metadata_path)
        parsed_title = parse_asdc_oracle_title(metadata["title"])
        unless parsed_title
          @unparsed << unparsed_row("oracle_metadata_title", metadata_path, metadata["title"])
          next
        end

        series, locator = parsed_title
        unless rules.key?(series)
          @unparsed << unparsed_row("unknown_oracle_series", metadata_path, series)
          next
        end

        docs = document_hashes(metadata)
        if docs.empty?
          @unparsed << unparsed_row("oracle_metadata_without_document", metadata_path, metadata["title"])
          next
        end

        docs.each do |document|
          source_file = locate_source_document(metadata_path.dirname, document)
          unless source_file&.file?
            @unparsed << unparsed_row("missing_oracle_document", metadata_path, document["file"] || document["path"])
            next
          end

          records << OracleRecord.new(
            series: series,
            locator: locator,
            source_label: "ASDC",
            metadata_path: metadata_path,
            metadata: metadata,
            document: document,
            source_file: source_file,
            work_id_candidate: true,
            material_type: "transcription",
            language_code: "zho"
          )
        end

        obsolete_metadata << relative_to_shang(metadata_path)
        count += 1
        maybe_progress(count, "oracle metadata folders")
      end
    else
      @warnings << { "kind" => "missing_source_root", "path" => "甲骨", "message" => "甲骨 source root not found; it may already have been migrated" }
    end

    progress "scanning legacy flat oracle sources"
    legacy_roots = descendants_named(@shang_root, "花園庄（洹北）") + descendants_named(@shang_root, "花園莊（洹北）")
    legacy_roots.uniq!

    legacy_roots.each do |legacy_root|
      legacy_root.glob("**/metadata.json").each do |metadata_path|
        metadata = read_json(metadata_path)
        docs = document_hashes(metadata)
        docs.each do |document|
          stem = File.basename(document["file"].to_s, ".txt")
          mapping = legacy_mapping_for(stem)
          unless mapping
            @unparsed << unparsed_row("unknown_legacy_oracle_filename", metadata_path, stem)
            next
          end

          source_file = locate_source_document(metadata_path.dirname, document)
          unless source_file&.file?
            @unparsed << unparsed_row("missing_legacy_oracle_document", metadata_path, document["file"] || document["path"])
            next
          end

          records << OracleRecord.new(
            series: mapping.fetch(:series),
            locator: mapping.fetch(:locator),
            source_label: mapping.fetch(:source_label),
            metadata_path: metadata_path,
            metadata: metadata,
            document: document,
            source_file: source_file,
            work_id_candidate: false,
            material_type: "transcription",
            language_code: "zho"
          )
        end
        obsolete_metadata << relative_to_shang(metadata_path)

        translation_root = child_named(metadata_path.dirname, "英譯文")
        if translation_root
          translation_root.glob("*.txt").sort.each do |source_file|
            stem = File.basename(decode_hash_u(source_file.basename.to_s), ".txt")
            mapping = legacy_mapping_for(stem)
            unless mapping
              @unparsed << unparsed_row("unknown_legacy_translation_filename", source_file, stem)
              next
            end

            records << OracleRecord.new(
              series: mapping.fetch(:series),
              locator: mapping.fetch(:locator),
              source_label: mapping.fetch(:source_label),
              metadata_path: metadata_path,
              metadata: metadata,
              document: {
                "document_id" => allocate_document_id,
                "file" => decode_hash_u(source_file.basename.to_s),
                "path" => corpus_document_path(relative_to_shang(source_file)),
                "title" => stem,
                "sources" => ["Schwartz", "A. C. Schwartz, The Oracle Bone Inscriptions from Huayuanzhuang East"],
                "identifiers" => [{ "scheme" => "catalog", "value" => stem }],
                "body_start_line" => legacy_body_start_line(source_file)
              },
              source_file: source_file,
              work_id_candidate: false,
              material_type: "translation",
              language_code: "eng"
            )
          end
        end

        metadata_path.dirname.glob("*.evidence.tsv").sort.each do |source_file|
          stem = decode_hash_u(source_file.basename.to_s).sub(/\.evidence\.tsv\z/, "")
          mapping = legacy_mapping_for(stem)
          unless mapping
            @unparsed << unparsed_row("unknown_legacy_evidence_filename", source_file, stem)
            next
          end
          support_records << {
            series: mapping.fetch(:series),
            locator: mapping.fetch(:locator),
            source_label: mapping.fetch(:source_label),
            source_file: source_file,
            kind: "transcription_review_evidence"
          }
        end

        review_index = metadata_path.dirname.join("REVIEW_INDEX.tsv")
        if review_index.file?
          support_records << {
            source_label: "Schwartz",
            source_file: review_index,
            kind: "review_index"
          }
        end
      end
    end

    progress "grouping #{records.length} oracle transcription/translation documents into physical objects"
    grouped = Hash.new { |hash, key| hash[key] = [] }

    records.each do |record|
      original_rule = rules.fetch(record.series)
      parsed = parse_locator(record.locator, original_rule.fetch("parser"))
      unless parsed
        @unparsed << unparsed_row("unparsed_oracle_locator", record.metadata_path, "#{record.series}: #{record.locator}")
        next
      end

      canonical_series, canonical_object, _concordance = oracle_concordance_for(record.series, parsed)
      unless rules.key?(canonical_series)
        @unparsed << unparsed_row("unknown_concordance_target_series", record.metadata_path, canonical_series)
        next
      end

      grouped[[canonical_series, canonical_object]] << [record, parsed, original_rule]
    end

    entries = []
    object_rows = []
    move_rows = []
    alias_rows = []
    entry_by_key = {}

    grouped.sort_by { |(series, object_value), _| [series, natural_identifier_key(object_value)] }.each_with_index do |((series, object_value), rows), index|
      base_rule = rules.fetch(series)
      override = oracle_overrides.fetch([series, object_value], {})
      rule = apply_oracle_override(base_rule, override)
      candidate_ids = rows.filter_map do |record, _parsed, _original_rule|
        integer_or_nil(record.metadata["work_id"]) if record.work_id_candidate
      end.uniq.sort
      work_id = candidate_ids.first || allocate_work_id
      legacy_work_ids = rows.filter_map do |record, _parsed, _original_rule|
        integer_or_nil(record.metadata["work_id"]) if record.work_id_candidate
      end.uniq.sort
      display_id = "#{rule.fetch('display_prefix')}#{normalize_display_object_value(object_value)}"
      target_folder = (Array(rule.fetch("target_path")) + [display_id]).join("/")

      planned_documents = build_oracle_documents(
        rows: rows,
        rule: rule,
        display_id: display_id,
        target_folder: target_folder,
        source_labels: source_labels
      )

      metadata = build_oracle_metadata(
        rows: rows,
        rule: rule,
        series: series,
        object_value: object_value,
        display_id: display_id,
        target_folder: target_folder,
        work_id: work_id,
        legacy_work_ids: legacy_work_ids,
        transcription_documents: planned_documents.select { |row| row["material_type"] == "transcription" }.map { |row| row.fetch("metadata") },
        translation_documents: planned_documents.select { |row| row["material_type"] == "translation" }.map { |row| row.fetch("metadata") }
      )

      moves = planned_documents.map { |row| row.fetch("move") }
      source_metadata_paths = rows.map { |record, _parsed, _original_rule| relative_to_shang(record.metadata_path) }.uniq.sort
      entry = {
        "kind" => "oracle_object",
        "work_id" => work_id,
        "title" => display_id,
        "target_folder" => target_folder,
        "metadata_target" => "#{target_folder}/metadata.json",
        "source_metadata_paths" => source_metadata_paths,
        "moves" => moves,
        "metadata" => metadata
      }
      entries << entry
      entry_by_key[[series, object_value]] = entry
      object_rows << plan_entry_csv_row(entry).merge(
        "series" => series,
        "canonical_identifier" => object_value,
        "source_work_count" => legacy_work_ids.length,
        "document_count" => moves.length,
        "override_applied" => override.empty? ? "no" : "yes"
      )
      move_rows.concat(moves.map { |move| move_csv_row(entry, move) })

      legacy_work_ids.each do |old_id|
        alias_rows << {
          "old_work_id" => old_id,
          "new_work_id" => work_id,
          "status" => old_id == work_id ? "retained_as_object_id" : "merged_into_object",
          "target_folder" => target_folder,
          "title" => display_id
        }
      end

      maybe_progress(index + 1, "oracle physical objects")
    end

    support_result = build_oracle_support_moves(
      support_records: support_records,
      entry_by_key: entry_by_key,
      rules: rules
    )
    support_result.fetch(:attached_moves).each do |work_id, moves|
      row = object_rows.find { |object_row| object_row["work_id"] == work_id }
      row["document_count"] = row["document_count"].to_i + moves.length if row
      entry = entries.find { |candidate| candidate["work_id"] == work_id }
      move_rows.concat(moves.map { |move| move_csv_row(entry, move) }) if entry
    end

    {
      entries: entries,
      object_rows: object_rows,
      move_rows: move_rows,
      alias_rows: alias_rows,
      extra_moves: support_result.fetch(:extra_moves),
      obsolete_metadata: obsolete_metadata
    }
  end

  def build_oracle_support_moves(support_records:, entry_by_key:, rules:)
    attached = Hash.new { |hash, key| hash[key] = [] }
    extra_moves = []
    seen_sources = Set.new

    support_records.each do |support|
      source_file = support.fetch(:source_file)
      next if seen_sources.include?(source_file.to_s)
      seen_sources << source_file.to_s

      if support[:kind] == "review_index"
        target = "商/甲骨文/殷墟/花園莊東地/H3/support/Schwartz/REVIEW_INDEX.tsv"
        extra_moves << support_move(source_file, target, support)
        next
      end

      original_rule = rules.fetch(support.fetch(:series))
      parsed = parse_locator(support.fetch(:locator), original_rule.fetch("parser"))
      unless parsed
        @unparsed << unparsed_row("unparsed_support_locator", source_file, support[:locator])
        next
      end
      canonical_series, canonical_object, _concordance = oracle_concordance_for(support.fetch(:series), parsed)
      entry = entry_by_key[[canonical_series, canonical_object]]
      unless entry
        @unparsed << unparsed_row("support_without_object", source_file, "#{canonical_series}:#{canonical_object}")
        next
      end

      prefix = original_rule.fetch("display_prefix")
      source_suffix = source_abbreviation(support.fetch(:source_label))
      file_name = sanitize_filename("#{prefix}#{parsed.normalized_locator}_#{source_suffix}.evidence.tsv")
      target = "#{entry.fetch('target_folder')}/support/#{source_suffix}/#{file_name}"
      move = support_move(source_file, target, support)
      entry["moves"] << move
      entry.fetch("metadata")["support_files"] ||= []
      entry.fetch("metadata")["support_files"] << {
        "kind" => support.fetch(:kind),
        "source_label" => support.fetch(:source_label),
        "source_locator" => parsed.normalized_locator,
        "file" => file_name,
        "path" => corpus_document_path(target)
      }
      attached[entry.fetch("work_id")] << move
    end

    { attached_moves: attached, extra_moves: extra_moves }
  end

  def support_move(source_file, target, support)
    {
      "source" => relative_to_shang(source_file),
      "target" => target,
      "sha256" => sha256(source_file),
      "byte_size" => source_file.size,
      "document_id" => nil,
      "material_type" => "support",
      "source_label" => support.fetch(:source_label),
      "source_locator" => support[:locator],
      "support_kind" => support.fetch(:kind)
    }
  end

  def apply_oracle_override(base_rule, override)
    rule = JSON.parse(JSON.generate(base_rule))
    return rule if override.nil? || override.empty?

    target_path = override["target_path"].to_s
    unless target_path.empty?
      parts = target_path.tr("\\", "/").split("/").reject(&:empty?)
      raise ArgumentError, "Unsafe target_path override: #{target_path}" if parts.empty? || parts.any? { |part| part == "." || part == ".." }
      rule["target_path"] = parts
    end

    %w[period polity local_polity region].each do |field|
      value = override[field].to_s
      rule[field] = value unless value.empty?
    end

    findspot = JSON.parse(JSON.generate(rule["findspot"] || {}))
    { "site" => "site", "area" => "area", "locus" => "locus" }.each do |column, field|
      value = override[column].to_s
      findspot[field] = value unless value.empty?
    end
    rule["findspot"] = findspot
    rule["override_source"] = override["source"] unless override["source"].to_s.empty?
    rule["override_note"] = override["note"] unless override["note"].to_s.empty?
    rule
  end

  def parse_asdc_oracle_title(title)
    parts = title.to_s.split("｜")
    return nil unless parts.length >= 5
    return nil unless parts[0] == "ASDC" && parts[1] == "甲骨"

    [parts[-2], parts[-1]]
  end

  def legacy_mapping_for(stem)
    Array(load_config["legacy_flat_sources"]).each do |rule|
      pattern = Regexp.new(rule.fetch("filename_pattern"))
      match = pattern.match(stem)
      next unless match

      return {
        series: rule.fetch("series"),
        locator: match[1],
        source_label: rule.fetch("source_label")
      }
    end
    nil
  end

  def parse_locator(locator, parser)
    normalized = locator.to_s.strip.tr("+", "＋")
    match = normalized.match(/\A(.+)\.(\d+)\z/)
    base = match ? match[1] : normalized
    segment = match ? match[2].to_i : nil

    case parser
    when "heji"
      heji = base.match(/\A(?<object>(?:\d+)(?:＋\d+)?)(?<surface>甲正|甲反|乙正|乙反|丙正|丙反|正|反|臼|甲|乙|丙)?\z/)
      return nil unless heji

      ParsedLocator.new(
        object_value: heji[:object],
        surface: heji[:surface],
        segment: segment,
        normalized_locator: normalized
      )
    when "generic_segment"
      return nil if base.empty?

      ParsedLocator.new(
        object_value: base,
        surface: nil,
        segment: segment,
        normalized_locator: normalized
      )
    else
      nil
    end
  end

  def normalize_display_object_value(value)
    value.to_s.tr("+", "＋")
  end

  def natural_identifier_key(value)
    value.to_s.split(/(\d+)/).map { |part| part.match?(/\A\d+\z/) ? [0, part.to_i, part.length] : [1, part] }
  end

  def locate_source_document(metadata_folder, document)
    file_name = document["file"].to_s
    direct = metadata_folder.join(file_name)
    return direct if !file_name.empty? && direct.file?

    path_value = document["path"].to_s
    return nil if path_value.empty?

    basename = File.basename(path_value)
    fallback = metadata_folder.join(basename)
    return fallback if fallback.file?

    decoded = Dir.children(metadata_folder).map { |name| utf8_string(name) }.find { |name| decode_hash_u(name) == basename }
    decoded && metadata_folder.join(decoded)
  rescue SystemCallError
    nil
  end

  def legacy_body_start_line(path)
    line_number = 1
    File.foreach(path, encoding: "UTF-8") do |line|
      if line.start_with?("#") || (line_number > 1 && line.strip.empty?)
        line_number += 1
        next
      end
      break
    end
    line_number
  rescue SystemCallError, EncodingError
    1
  end

  def build_oracle_documents(rows:, rule:, display_id:, target_folder:, source_labels:)
    used_names = Set.new

    rows.sort_by do |record, parsed, original_rule|
      [record.material_type.to_s, original_rule.fetch("display_prefix"), parsed.surface.to_s,
       parsed.segment || -1, record.source_label.to_s,
       integer_or_nil(record.document["document_id"]) || 0]
    end.map do |record, parsed, original_rule|
      source_label = record.source_label
      source_suffix = source_abbreviation(source_label)
      locator_display = "#{original_rule.fetch('display_prefix')}#{parsed.normalized_locator}"
      proposed = sanitize_filename("#{locator_display}_#{source_suffix}.txt")
      document_id = integer_or_nil(record.document["document_id"]) || allocate_document_id
      material_type = record.material_type.to_s.empty? ? "transcription" : record.material_type.to_s
      subfolder = if material_type == "translation"
        "translation/#{record.language_code || 'und'}/#{source_suffix}"
      end
      name_key = [subfolder.to_s, proposed]

      if used_names.include?(name_key)
        stem = File.basename(proposed, ".txt")
        proposed = "#{stem}_d#{document_id}.txt"
        name_key = [subfolder.to_s, proposed]
      end
      used_names << name_key

      target_relative = [target_folder, subfolder, proposed].compact.reject(&:empty?).join("/")
      source_relative = relative_to_shang(record.source_file)
      source_info = source_labels[source_label] || {}
      body_start_line = if source_label == "ASDC"
        1
      else
        integer_or_nil(record.document["body_start_line"]) || legacy_body_start_line(record.source_file)
      end

      metadata = deep_compact(
        {
          "document_id" => document_id,
          "file" => proposed,
          "path" => corpus_document_path(target_relative),
          "title" => locator_display,
          "surface" => parsed.surface,
          "segment" => parsed.segment,
          "source_locator" => parsed.normalized_locator,
          "material_type" => material_type,
          "language_code" => record.language_code,
          "transcription_source" => material_type == "transcription" ? (source_info["name"] || source_label) : nil,
          "translation_source" => material_type == "translation" ? (source_info["name"] || source_label) : nil,
          "source_label" => source_label,
          "catalogue" => original_rule.fetch("canonical_scheme"),
          "sources" => unique_array(Array(record.document["sources"])),
          "identifiers" => unique_array(Array(record.document["identifiers"])),
          "body_start_line" => body_start_line
        }
      )

      move = {
        "source" => source_relative,
        "target" => target_relative,
        "sha256" => sha256(record.source_file),
        "byte_size" => record.source_file.size,
        "document_id" => document_id,
        "material_type" => material_type,
        "language_code" => record.language_code,
        "source_label" => source_label,
        "source_locator" => parsed.normalized_locator
      }

      { "metadata" => metadata, "move" => move, "material_type" => material_type }
    end
  end

  def build_oracle_metadata(rows:, rule:, series:, object_value:, display_id:, target_folder:, work_id:, legacy_work_ids:, transcription_documents:, translation_documents:)
    metadata_rows = rows.map { |record, _parsed, _original_rule| record.metadata }
    identifiers = rows.flat_map do |record, parsed, original_rule|
      base = [{ "scheme" => original_rule.fetch("canonical_scheme"), "value" => parsed.object_value }]
      if record.work_id_candidate
        base + Array(record.metadata["identifiers"]) + Array(record.document["identifiers"])
      else
        base + Array(record.document["identifiers"])
      end
    end
    identifiers.unshift({ "scheme" => rule.fetch("canonical_scheme"), "value" => object_value })

    legacy_work_ids.each do |legacy_id|
      identifiers << { "scheme" => "legacy_work_id", "value" => legacy_id.to_s } unless legacy_id == work_id
    end

    sources = metadata_rows.flat_map { |metadata| Array(metadata["sources"]) }
    sources << rule["override_source"] if rule["override_source"]
    categories = metadata_rows.flat_map { |metadata| Array(metadata["categories"]) }
    categories.concat(["甲骨文", "出土文獻"])

    transcriptions = transcription_documents.group_by { |doc| [doc["source_label"], doc["catalogue"]] }.map do |(source_label, catalogue), docs|
      {
        "source" => docs.first["transcription_source"],
        "source_label" => source_label,
        "catalogue" => catalogue,
        "documents" => docs.filter_map { |doc| doc["document_id"] }
      }
    end.sort_by { |row| [row["source_label"].to_s, row["catalogue"].to_s] }

    translations = translation_documents.group_by { |doc| [doc["source_label"], doc["language_code"]] }.map do |(source_label, language_code), docs|
      {
        "source" => docs.first["translation_source"],
        "source_label" => source_label,
        "language_code" => language_code,
        "language" => language_code == "eng" ? "English" : nil,
        "documents" => docs
      }
    end.sort_by { |row| [row["language_code"].to_s, row["source_label"].to_s] }

    corpus = load_config.fetch("corpus")

    deep_compact(
      {
        "schema_version" => load_config.fetch("schema_version", 1),
        "work_id" => work_id,
        "legacy_work_ids" => legacy_work_ids.reject { |id| id == work_id },
        "corpus_root" => corpus.fetch("corpus_root"),
        "macro_region" => corpus.fetch("macro_region"),
        "period" => rule["period"] || corpus.fetch("period"),
        "polity" => rule["polity"] || corpus.fetch("polity"),
        "local_polity" => rule["local_polity"] || corpus.fetch("local_polity"),
        "region" => rule["region"],
        "title" => display_id,
        "object_type" => "甲骨",
        "medium" => "甲骨文",
        "findspot" => rule["findspot"],
        "canonical_identifier" => {
          "scheme" => rule.fetch("canonical_scheme"),
          "value" => object_value
        },
        "identifiers" => unique_array(identifiers),
        "categories" => unique_array(categories),
        "sources" => unique_array(sources),
        "notes" => unique_array(metadata_rows.flat_map { |metadata| Array(metadata["notes"]) } + Array(rule["override_note"])),
        "is_compilation" => false,
        "documents" => transcription_documents,
        "transcriptions" => transcriptions,
        "variants" => unique_array(metadata_rows.flat_map { |metadata| Array(metadata["variants"]) }),
        "translations" => unique_array(metadata_rows.flat_map { |metadata| Array(metadata["translations"]) } + translations),
        "images" => unique_array(metadata_rows.flat_map { |metadata| Array(metadata["images"]) }),
        "known_commentaries" => unique_array(metadata_rows.flat_map { |metadata| Array(metadata["known_commentaries"]) })
      }
    )
  end

  def build_bronze_plan
    bronze_root = child_named(@shang_root, "金文")
    unless bronze_root
      @warnings << { "kind" => "missing_source_root", "path" => "金文", "message" => "金文 source root not found; it may already have been migrated" }
      return { entries: [], object_rows: [], move_rows: [], alias_rows: [], obsolete_metadata: Set.new }
    end

    bronze_config = load_config.fetch("bronze")
    target_root = Array(bronze_config.fetch("target_root"))
    period_names = bronze_config.fetch("period_folder_names", {})
    entries = []
    object_rows = []
    move_rows = []
    alias_rows = []
    obsolete_metadata = Set.new
    count = 0

    bronze_root.glob("**/metadata.json").each do |metadata_path|
      next if metadata_path == bronze_root.join("metadata.json")

      metadata = read_json(metadata_path)
      source_folder = metadata_path.dirname
      source_relative_folder = source_folder.relative_path_from(bronze_root).to_s.tr("\\", "/")
      decoded_parts = source_relative_folder.split("/").map { |part| decode_hash_u(part) }
      identity = bronze_identity(metadata, bronze_config)
      unless identity
        @unparsed << unparsed_row("unknown_bronze_catalogue", metadata_path, metadata["title"])
        next
      end

      period_folder = decoded_parts.length > 1 ? period_names.fetch(decoded_parts.first, decoded_parts.first) : nil
      target_folder = (target_root + Array(period_folder) + [identity.fetch(:display_id)]).join("/")

      docs = document_hashes(metadata)
      if docs.empty?
        @unparsed << unparsed_row("bronze_metadata_without_document", metadata_path, metadata["title"])
        next
      end

      planned_docs = []
      moves = []
      used_names = Set.new
      docs.each do |document|
        source_file = locate_source_document(source_folder, document)
        unless source_file&.file?
          @unparsed << unparsed_row("missing_bronze_document", metadata_path, document["file"] || document["path"])
          next
        end

        source_label = metadata["title"].to_s.start_with?("ASDC｜") ? "ASDC" : "existing"
        file_name = sanitize_filename("#{identity.fetch(:display_id)}_#{source_abbreviation(source_label)}.txt")
        if used_names.include?(file_name)
          stem = File.basename(file_name, ".txt")
          file_name = "#{stem}_d#{integer_or_nil(document['document_id']) || allocate_document_id}.txt"
        end
        used_names << file_name
        target_relative = "#{target_folder}/#{file_name}"
        source_relative = relative_to_shang(source_file)
        new_doc = deep_compact(document.merge(
          "file" => file_name,
          "path" => corpus_document_path(target_relative),
          "title" => identity.fetch(:display_id),
          "catalogue" => identity[:canonical_scheme],
          "source_locator" => identity[:object_value],
          "transcription_source" => source_label == "ASDC" ? load_config.dig("source_labels", "ASDC", "name") : source_label,
          "transcription_source_label" => source_label,
          "body_start_line" => 1
        ).reject { |key, _| key == "geography_override" })
        planned_docs << new_doc
        moves << {
          "source" => source_relative,
          "target" => target_relative,
          "sha256" => sha256(source_file),
          "byte_size" => source_file.size,
          "document_id" => integer_or_nil(document["document_id"]),
          "source_label" => source_label,
          "source_locator" => File.basename(file_name, ".txt")
        }
      end

      next if planned_docs.empty?

      work_id = integer_or_nil(metadata["work_id"]) || allocate_work_id
      updated = build_bronze_metadata(metadata, planned_docs, bronze_config, identity)
      updated["work_id"] = work_id

      entry = {
        "kind" => "bronze_object",
        "work_id" => work_id,
        "title" => updated["title"],
        "target_folder" => target_folder,
        "metadata_target" => "#{target_folder}/metadata.json",
        "source_metadata_paths" => [relative_to_shang(metadata_path)],
        "moves" => moves,
        "metadata" => updated
      }
      entries << entry
      object_rows << plan_entry_csv_row(entry).merge(
        "series" => identity[:catalogue],
        "canonical_identifier" => identity[:object_value],
        "source_work_count" => 1,
        "document_count" => moves.length
      )
      move_rows.concat(moves.map { |move| move_csv_row(entry, move) })
      alias_rows << {
        "old_work_id" => work_id,
        "new_work_id" => work_id,
        "status" => "retained_as_object_id",
        "target_folder" => target_folder,
        "title" => updated["title"]
      }
      obsolete_metadata << relative_to_shang(metadata_path)
      count += 1
      maybe_progress(count, "bronze objects")
    end

    {
      entries: entries,
      object_rows: object_rows,
      move_rows: move_rows,
      alias_rows: alias_rows,
      obsolete_metadata: obsolete_metadata
    }
  end

  def bronze_identity(metadata, bronze_config)
    title = metadata["title"].to_s
    parts = title.split("｜")
    if parts.length >= 5 && parts[0] == "ASDC" && parts[1] == "金文"
      catalogue = parts[-2]
      object_value = parts[-1].to_s.strip
      catalogue_rule = bronze_config.fetch("catalogues", {})[catalogue]
      return nil unless catalogue_rule && !object_value.empty?

      return {
        catalogue: catalogue,
        canonical_scheme: catalogue_rule.fetch("canonical_scheme"),
        object_value: object_value,
        display_id: "#{catalogue_rule.fetch('display_prefix')}#{object_value}"
      }
    end

    display_id = title.empty? ? decode_hash_u(metadata.fetch("path", "")) : title
    return nil if display_id.to_s.empty?

    {
      catalogue: nil,
      canonical_scheme: nil,
      object_value: nil,
      display_id: display_id
    }
  end

  def build_bronze_metadata(metadata, documents, bronze_config, identity)
    updated = metadata.dup
    updated.delete("contained_in")
    updated.delete("editions")
    updated["polity"] ||= load_config.dig("corpus", "polity")
    updated["local_polity"] ||= load_config.dig("corpus", "local_polity")
    updated["medium"] ||= bronze_config.fetch("medium")
    updated["object_type"] ||= bronze_config.fetch("object_type")
    updated["title"] = identity.fetch(:display_id)
    updated["is_compilation"] = false
    updated["documents"] = documents
    if identity[:canonical_scheme] && identity[:object_value]
      updated["canonical_identifier"] = {
        "scheme" => identity[:canonical_scheme],
        "value" => identity[:object_value]
      }
      updated["identifiers"] = unique_array(
        [updated["canonical_identifier"]] + Array(updated["identifiers"]) +
        [{ "scheme" => "source_record_title", "value" => metadata["title"] }]
      )
    end
    updated["variants"] ||= []
    updated["translations"] ||= []
    updated["images"] ||= []

    if metadata["title"].to_s.start_with?("ASDC｜")
      catalogue = identity[:canonical_scheme] || identity[:catalogue]
      source_name = load_config.dig("source_labels", "ASDC", "name") || "ASDC"
      updated["transcriptions"] = [
        {
          "source" => source_name,
          "source_label" => "ASDC",
          "catalogue" => catalogue,
          "documents" => documents.filter_map { |doc| integer_or_nil(doc["document_id"]) }
        }
      ]
    else
      updated["transcriptions"] ||= []
    end

    deep_compact(updated)
  end

  def bronze_catalogue_from_title(title)
    parts = title.to_s.split("｜")
    parts.length >= 5 ? parts[-2] : nil
  end

  def bronze_identifier_from_metadata(metadata)
    identifier = Array(metadata["identifiers"]).find { |row| row.is_a?(Hash) && row["scheme"] == "legacy_id" }
    identifier && identifier["value"]
  end

  def build_collection_entries(entries)
    result = []
    corpus = load_config.fetch("corpus")

    oracle_entries = entries.select { |entry| entry["kind"] == "oracle_object" }
    if oracle_entries.any?
      old_path = child_named(@shang_root, "甲骨")&.join("metadata.json")
      old = old_path&.file? ? read_json(old_path) : {}
      work_id = integer_or_nil(old["work_id"]) || allocate_work_id
      legacy_collection_paths = (descendants_named(@shang_root, "花園庄（洹北）") + descendants_named(@shang_root, "花園莊（洹北）")).uniq.flat_map do |root|
        root.glob("**/metadata.json").select(&:file?)
      end
      legacy_collection_ids = legacy_collection_paths.filter_map do |path|
        integer_or_nil(read_json(path)["work_id"])
      end.uniq.sort.reject { |id| id == work_id }
      metadata = {
        "schema_version" => load_config.fetch("schema_version", 1),
        "work_id" => work_id,
        "legacy_work_ids" => legacy_collection_ids,
        "corpus_root" => corpus.fetch("corpus_root"),
        "macro_region" => corpus.fetch("macro_region"),
        "period" => corpus.fetch("period"),
        "polity" => corpus.fetch("polity"),
        "local_polity" => corpus.fetch("local_polity"),
        "title" => "甲骨文",
        "categories" => unique_array(Array(old["categories"]) + ["甲骨文", "出土文獻"]),
        "medium" => "甲骨文",
        "is_compilation" => true,
        "collection_type" => "inscription_medium",
        "worklist" => oracle_entries.sort_by { |entry| natural_identifier_key(entry["title"]) }.map do |entry|
          { "work_id" => entry["work_id"], "title" => entry["title"], "path" => entry["target_folder"] }
        end
      }
      result << {
        "kind" => "oracle_collection",
        "work_id" => work_id,
        "title" => "甲骨文",
        "target_folder" => "商/甲骨文",
        "metadata_target" => "商/甲骨文/metadata.json",
        "source_metadata_paths" => ([old_path].compact.select(&:file?) + legacy_collection_paths).map { |path| relative_to_shang(path) }.uniq.sort,
        "moves" => [],
        "metadata" => deep_compact(metadata)
      }
    end

    bronze_entries = entries.select { |entry| entry["kind"] == "bronze_object" }
    if bronze_entries.any?
      old_path = child_named(@shang_root, "金文")&.join("metadata.json")
      old = old_path&.file? ? read_json(old_path) : {}
      work_id = integer_or_nil(old["work_id"]) || allocate_work_id
      metadata = {
        "schema_version" => load_config.fetch("schema_version", 1),
        "work_id" => work_id,
        "corpus_root" => corpus.fetch("corpus_root"),
        "macro_region" => corpus.fetch("macro_region"),
        "period" => corpus.fetch("period"),
        "polity" => corpus.fetch("polity"),
        "local_polity" => corpus.fetch("local_polity"),
        "title" => "金文",
        "categories" => unique_array(Array(old["categories"]) + ["金文", "出土文獻"]),
        "medium" => "金文",
        "is_compilation" => true,
        "collection_type" => "inscription_medium",
        "worklist" => bronze_entries.sort_by { |entry| natural_identifier_key(entry["title"]) }.map do |entry|
          { "work_id" => entry["work_id"], "title" => entry["title"], "path" => entry["target_folder"] }
        end
      }
      result << {
        "kind" => "bronze_collection",
        "work_id" => work_id,
        "title" => "金文",
        "target_folder" => "商/金文",
        "metadata_target" => "商/金文/metadata.json",
        "source_metadata_paths" => old_path&.file? ? [relative_to_shang(old_path)] : [],
        "moves" => [],
        "metadata" => deep_compact(metadata)
      }
    end

    result
  end

  def unparsed_row(kind, path, value)
    {
      "kind" => kind,
      "path" => relative_to_shang(path),
      "value" => value.to_s
    }
  end

  def plan_entry_csv_row(entry)
    {
      "kind" => entry["kind"],
      "work_id" => entry["work_id"],
      "title" => entry["title"],
      "target_folder" => entry["target_folder"],
      "metadata_target" => entry["metadata_target"],
      "source_work_count" => Array(entry["source_metadata_paths"]).length,
      "document_count" => Array(entry["moves"]).length
    }
  end

  def move_csv_row(entry, move)
    {
      "kind" => entry["kind"],
      "work_id" => entry["work_id"],
      "title" => entry["title"],
      "source" => move["source"],
      "target" => move["target"],
      "document_id" => move["document_id"],
      "source_label" => move["source_label"],
      "source_locator" => move["source_locator"],
      "byte_size" => move["byte_size"],
      "sha256" => move["sha256"]
    }
  end

  def extra_move_csv_row(move)
    {
      "kind" => "support_file",
      "work_id" => nil,
      "title" => move["support_kind"],
      "source" => move["source"],
      "target" => move["target"],
      "document_id" => nil,
      "source_label" => move["source_label"],
      "source_locator" => move["source_locator"],
      "byte_size" => move["byte_size"],
      "sha256" => move["sha256"]
    }
  end

  def build_updated_registry(entries, alias_rows)
    load_id_registry!
    replacements = {}
    changes = []
    planned_work_ids = {}
    planned_document_ids = {}
    entry_by_work_id = entries.to_h { |entry| [integer_or_nil(entry["work_id"]), entry] }

    entries.each do |entry|
      work_id = integer_or_nil(entry["work_id"])
      raise ArgumentError, "Plan entry lacks a valid work_id: #{entry['target_folder']}" unless work_id
      if planned_work_ids.key?(work_id)
        raise ArgumentError, "Planned work ID #{work_id} is used by both #{planned_work_ids[work_id]} and #{entry['target_folder']}"
      end
      planned_work_ids[work_id] = entry.fetch("target_folder")

      target_path = registry_full_work_path(entry.fetch("target_folder"))
      base = @registry_by_kind_id[["work", work_id]]
      assert_registry_owner_is_shang!(base, "work", work_id) if base
      replacement = registry_row(
        kind: "work", id: work_id, path: target_path, title: entry["title"],
        status: "active", base: base
      )
      replacements[["work", work_id]] = replacement
      changes << registry_change_row(base, replacement, "activate_physical_object")

      registry_document_hashes(entry.fetch("metadata")).each do |document|
        document_id = integer_or_nil(document["document_id"])
        next unless document_id
        if planned_document_ids.key?(document_id)
          raise ArgumentError, "Planned document ID #{document_id} is used by both #{planned_document_ids[document_id]} and #{document['path']}"
        end
        planned_document_ids[document_id] = document["path"]

        path = normalize_registry_path(document.fetch("path"))
        base_document = @registry_by_kind_id[["document", document_id]]
        assert_registry_owner_is_shang!(base_document, "document", document_id) if base_document
        title = document["title"].to_s.strip
        title = File.basename(path, File.extname(path)) if title.empty?
        document_row = registry_row(
          kind: "document", id: document_id, path: path, title: title,
          parent_work_id: work_id, status: "active", base: base_document
        )
        replacements[["document", document_id]] = document_row
        changes << registry_change_row(base_document, document_row, "move_document")
      end
    end

    alias_rows.each do |alias_row|
      old_id = integer_or_nil(alias_row["old_work_id"])
      new_id = integer_or_nil(alias_row["new_work_id"])
      next unless old_id && new_id
      next if old_id == new_id

      entry = entry_by_work_id[new_id]
      raise ArgumentError, "Alias #{old_id} points to missing planned work #{new_id}" unless entry
      if planned_work_ids.key?(old_id)
        raise ArgumentError, "Merged legacy work ID #{old_id} is also an active planned object"
      end

      base = @registry_by_kind_id[["work", old_id]]
      assert_registry_owner_is_shang!(base, "work", old_id) if base
      target_path = registry_full_work_path(entry.fetch("target_folder"))
      alias_registry_row = registry_row(
        kind: "work", id: old_id, path: target_path, title: entry["title"],
        parent_work_id: new_id,
        status: "merged_into_work:#{new_id}",
        identity_key: "work_alias:#{old_id}",
        base: base
      )
      replacements[["work", old_id]] = alias_registry_row
      changes << registry_change_row(base, alias_registry_row, "preserve_legacy_work_alias")
    end

    updated_rows = @registry_rows.map do |row|
      key = [row["kind"].to_s, integer_or_nil(row["id"])]
      replacements.delete(key) || row
    end
    updated_rows.concat(replacements.values)
    validate_updated_registry!(updated_rows)

    action_counts = changes.group_by { |row| row["action"] }.transform_values(&:length)
    {
      rows: updated_rows,
      changes: changes,
      summary: {
        "rows_before" => @registry_rows.length,
        "rows_after" => updated_rows.length,
        "work_max_before" => registry_max_id("work"),
        "work_max_after" => updated_rows.filter_map { |row| integer_or_nil(row["id"]) if row["kind"] == "work" }.max.to_i,
        "document_max_before" => registry_max_id("document"),
        "document_max_after" => updated_rows.filter_map { |row| integer_or_nil(row["id"]) if row["kind"] == "document" }.max.to_i,
        "actions" => action_counts
      }
    }
  end

  def assert_registry_owner_is_shang!(row, kind, id)
    path = normalize_registry_path(row["path"])
    return if path.empty?

    shang_prefix = [@corpus_prefix, "商殷朝"].join("/")
    return if path == shang_prefix || path.start_with?("#{shang_prefix}/")

    raise ArgumentError, "Global registry collision: #{kind} ID #{id} belongs outside 商殷朝 at #{path}"
  end

  def registry_change_row(before, after, action)
    {
      "action" => action,
      "kind" => after["kind"],
      "id" => after["id"],
      "old_identity_key" => before&.fetch("identity_key", nil),
      "new_identity_key" => after["identity_key"],
      "old_path" => before&.fetch("path", nil),
      "new_path" => after["path"],
      "old_parent_work_id" => before&.fetch("parent_work_id", nil),
      "new_parent_work_id" => after["parent_work_id"],
      "old_status" => before&.fetch("status", nil),
      "new_status" => after["status"]
    }
  end

  def validate_updated_registry!(rows)
    seen_ids = {}
    seen_identity = {}

    rows.each do |row|
      kind = row["kind"].to_s
      id = integer_or_nil(row["id"])
      raise ArgumentError, "Updated registry contains an invalid row: #{row.inspect}" if kind.empty? || !id

      id_key = [kind, id]
      if seen_ids.key?(id_key)
        raise ArgumentError, "Updated registry duplicates #{kind} ID #{id}"
      end
      seen_ids[id_key] = row["path"]

      identity_key = row["identity_key"].to_s
      next if identity_key.empty?
      identity = [kind, identity_key]
      if seen_identity.key?(identity)
        raise ArgumentError, "Updated registry duplicates #{kind} identity #{identity_key}"
      end
      seen_identity[identity] = id
    end
  end

  def write_registry_csv(path, rows)
    FileUtils.mkdir_p(path.dirname)
    CSV.open(path, "w", write_headers: true, headers: @registry_headers, encoding: "UTF-8") do |csv|
      rows.sort_by { |row| [row["kind"].to_s, integer_or_nil(row["id"]) || 0] }.each do |row|
        csv << @registry_headers.map { |header| row[header] }
      end
    end
  end

  def write_plan_outputs(plan, object_rows, move_rows, alias_rows)
    progress "writing exact migration plan"
    atomic_write_json(@output.join("migration_plan.json"), plan)
    write_csv(@output.join("object_plan.csv"), object_rows)
    write_csv(@output.join("document_moves.csv"), move_rows)
    write_csv(@output.join("work_id_aliases.csv"), alias_rows)
    write_csv(@output.join("unparsed.csv"), @unparsed)
    write_csv(@output.join("warnings.csv"), @warnings)
    write_csv(
      @output.join("folder_skeleton.csv"),
      Array(plan["folder_skeleton"]).map { |path| { "path" => path } }
    )

    summary = {
      "generated_at" => plan["generated_at"],
      "scope" => plan["scope"],
      "entries" => plan["entries"].length,
      "oracle_objects" => plan["entries"].count { |entry| entry["kind"] == "oracle_object" },
      "bronze_objects" => plan["entries"].count { |entry| entry["kind"] == "bronze_object" },
      "document_moves" => move_rows.length,
      "work_id_aliases" => alias_rows.length,
      "unparsed" => @unparsed.length,
      "warnings" => @warnings.length,
      "next_allocated_work_id" => @next_work_id,
      "next_allocated_document_id" => @next_document_id,
      "id_registry_sha256" => plan["id_registry_sha256"],
      "updated_id_registry_sha256" => plan["updated_id_registry_sha256"],
      "registry_changes" => plan["registry_changes"],
      "elapsed_seconds" => elapsed
    }
    atomic_write_json(@output.join("summary.json"), summary)
    @output.join("REGIONALISATION_REPORT.md").write(report_markdown(plan, summary), encoding: "UTF-8")
  end

  def write_csv(path, rows)
    rows = Array(rows)
    headers = rows.flat_map(&:keys).uniq
    headers = ["status"] if headers.empty?

    CSV.open(path, "w", write_headers: true, headers: headers, encoding: "UTF-8") do |csv|
      rows.each { |row| csv << headers.map { |header| row[header] } }
    end
  end

  def report_markdown(plan, summary)
    blocked = summary["unparsed"].positive?
    <<~MARKDOWN
      # Shang inscription regionalisation plan

      Generated: #{summary["generated_at"]}

      Mode: **DRY RUN / PLAN ONLY**

      Apply status: **#{blocked ? 'BLOCKED: unparsed rows remain' : 'eligible after manual review'}**

      ## Counts

      - Physical oracle-bone objects: #{summary["oracle_objects"]}
      - Bronze object records: #{summary["bronze_objects"]}
      - Planned document moves: #{summary["document_moves"]}
      - Work-ID alias rows: #{summary["work_id_aliases"]}
      - Unparsed/problem rows: #{summary["unparsed"]}
      - Warnings: #{summary["warnings"]}
      - Global registry rows before: #{plan.dig("registry_changes", "rows_before")}
      - Global registry rows after: #{plan.dig("registry_changes", "rows_after")}
      - Global maximum work ID before/after: #{plan.dig("registry_changes", "work_max_before")} → #{plan.dig("registry_changes", "work_max_after")}
      - Global maximum document ID before/after: #{plan.dig("registry_changes", "document_max_before")} → #{plan.dig("registry_changes", "document_max_after")}

      ## What this plan does

      - Places a local polity level (`商`, `周方`, etc.) below `商殷朝`.
      - Collapses ASDC sentence rows into physical oracle-bone work folders.
      - Uses conventional catalogue prefixes (`合集`, `屯南`, `英藏`, `懷`, `東文研`, `花東`).
      - Reuses the lowest existing segment `work_id` as the physical object's stable ID.
      - Records every other old segment work ID as a legacy alias.
      - Keeps every transcription document and document ID.
      - Allocates every new ID above the authoritative corpus-wide registry maxima.
      - Rewrites moved work/document registry paths and records merged sentence works as aliases.
      - Splits the exceptional `HYZ 0.6`, `HYZ 0.7`, and `HYZ 0.9` records by their explicit H3 excavation identifiers rather than inventing `花東0`.
      - Adds `transcriptions`, `variants`, `translations`, and `images` arrays to object metadata.
      - Moves the existing bronze objects beneath `商/金文` without attempting unsafe cross-catalogue deduplication.
      - Creates the reviewed empty folder skeleton for future Shang-aligned writing finds.

      ## What this plan deliberately does not do

      - It does not download or create images.
      - It does not infer cross-catalogue concordances between, for example, `合集` and `英藏`.
      - It does not move ambiguous transition-period material into Western Zhou.
      - It does not edit Rails routes.

      ## Review files

      - `object_plan.csv`: one row per physical object or collection.
      - `document_moves.csv`: exact old path, new path, document ID, size, and SHA-256.
      - `work_id_aliases.csv`: old sentence-work IDs mapped to the retained object work ID.
      - `unparsed.csv`: anything the script refused to guess.
      - `warnings.csv`: non-blocking observations.
      - `id_registry_changes.csv`: every registry row added or rewritten.
      - `metadata_id_registry.updated.csv`: complete reviewed replacement registry.
      - `migration_plan.json`: the exact reviewed plan used by apply mode.

      ## Apply command

      ```bash
      ruby script/shang_inscription_regionalisation.rb \\
        --shang-root ../corpus/中國漢文/clean/商殷朝 \\
        --config config/corpus_metadata/shang_inscription_regionalisation.yml \\
        --concordances config/corpus_metadata/shang_oracle_concordances.csv \\
        --overrides config/corpus_metadata/shang_oracle_overrides.csv \\
        --id-registry #{ShellwordsEscape.path(@id_registry_path)} \\
        --reviewed-plan #{ShellwordsEscape.path(@output)} \\
        --apply
      ```

      Apply mode rechecks every source file and the authoritative ID registry before moving anything. It writes backups of old `metadata.json` files and the registry into the reviewed plan folder.
    MARKDOWN
  end

  # Tiny escaping helper kept local so the script does not need shellwords for
  # anything except a readable command in the report.
  module ShellwordsEscape
    module_function

    def path(path)
      value = path.to_s
      return value if value.match?(/\A[\p{L}\p{N}_\.\/-]+\z/u)

      "'#{value.gsub("'", %q('\\''))}'"
    end
  end

  # ------------------------------------------------------------------------
  # Apply a reviewed plan
  # ------------------------------------------------------------------------

  def apply_reviewed_plan!
    plan_path = @reviewed_plan.directory? ? @reviewed_plan.join("migration_plan.json") : @reviewed_plan
    raise ArgumentError, "Reviewed plan not found: #{plan_path}" unless plan_path.file?

    progress "loading reviewed plan #{plan_path}"
    plan = read_json(plan_path)
    validate_reviewed_plan!(plan)

    plan_root = plan_path.dirname
    updated_registry_path = plan_root.join(plan.fetch("updated_id_registry_file"))
    raise ArgumentError, "Reviewed updated registry not found: #{updated_registry_path}" unless updated_registry_path.file?
    unless sha256(updated_registry_path) == plan.fetch("updated_id_registry_sha256")
      raise ArgumentError, "Reviewed updated registry changed after plan generation: #{updated_registry_path}"
    end

    applied_marker = plan_root.join("APPLIED.json")
    if applied_marker.file?
      raise ArgumentError, "This plan already has APPLIED.json. Refusing a second apply: #{applied_marker}"
    end

    progress "preflight: checking every source/target hash"
    preflight_plan_files!(plan)

    progress "backing up original metadata sidecars and authoritative ID registry"
    backup_metadata!(plan, plan_root)
    backup_id_registry!(plan, plan_root)

    progress "creating regional folder skeleton"
    Array(plan["folder_skeleton"]).each { |relative| FileUtils.mkdir_p(absolute_from_shang(relative)) }

    moves = Array(plan["entries"]).flat_map { |entry| Array(entry["moves"]) } + Array(plan["extra_moves"])
    progress "moving #{moves.length} corpus/support files"
    moves.each_with_index do |move, index|
      apply_move!(move)
      maybe_progress(index + 1, "applied document moves")
    end

    progress "writing #{Array(plan['entries']).length} metadata sidecars"
    Array(plan["entries"]).each_with_index do |entry, index|
      target = absolute_from_shang(entry.fetch("metadata_target"))
      atomic_write_json(target, entry.fetch("metadata"))
      maybe_progress(index + 1, "metadata writes")
    end

    progress "removing superseded metadata sidecars"
    metadata_targets = Set.new(Array(plan["entries"]).map { |entry| entry["metadata_target"] })
    Array(plan["obsolete_metadata"]).each do |relative|
      path = absolute_from_shang(relative)
      next unless path.file?
      next if metadata_targets.include?(relative)

      FileUtils.rm_f(path)
    end

    progress "installing reviewed global ID-registry update"
    install_updated_id_registry!(plan, plan_root)

    progress "removing empty legacy directories"
    remove_empty_directories!

    marker = {
      "applied_at" => Time.now.utc.iso8601,
      "plan_generated_at" => plan["generated_at"],
      "shang_root" => @shang_root.to_s,
      "entries" => Array(plan["entries"]).length,
      "moves" => moves.length,
      "id_registry_sha256" => sha256(@id_registry_path),
      "elapsed_seconds" => elapsed
    }
    atomic_write_json(applied_marker, marker)
    progress "apply complete: moves=#{moves.length} metadata=#{Array(plan['entries']).length} elapsed=#{elapsed}s"
  end

  def validate_reviewed_plan!(plan)
    raise ArgumentError, "Unsupported plan version #{plan['plan_version']}" unless plan["plan_version"].to_i == PLAN_VERSION
    raise ArgumentError, "Reviewed plan has #{plan['unparsed_count']} unparsed rows; fix and regenerate" if plan["unparsed_count"].to_i.positive?

    unless plan["config_sha256"].to_s == config_sha256
      raise ArgumentError, "Config changed after the plan was generated. Regenerate the plan before applying."
    end
    unless plan["concordance_sha256"].to_s == concordance_sha256.to_s
      raise ArgumentError, "Concordance CSV changed after the plan was generated. Regenerate the plan before applying."
    end
    unless plan["override_sha256"].to_s == override_sha256.to_s
      raise ArgumentError, "Override CSV changed after the plan was generated. Regenerate the plan before applying."
    end

    current_registry_sha = id_registry_sha256
    allowed_registry_shas = [plan["id_registry_sha256"], plan["updated_id_registry_sha256"]].compact.map(&:to_s)
    unless allowed_registry_shas.include?(current_registry_sha)
      raise ArgumentError, "Authoritative ID registry changed after the plan was generated. Regenerate the plan before applying."
    end
  end

  def preflight_plan_files!(plan)
    problems = []

    (Array(plan["entries"]).flat_map { |entry| Array(entry["moves"]) } + Array(plan["extra_moves"])).each do |move|
      source = absolute_from_shang(move.fetch("source"))
      target = absolute_from_shang(move.fetch("target"))
      expected = move.fetch("sha256")

      if source.file?
        actual = sha256(source)
        problems << "source hash changed: #{move['source']}" unless actual == expected
        if target.file? && sha256(target) != expected
          problems << "different target already exists: #{move['target']}"
        end
      elsif target.file? && sha256(target) == expected
        # Resume-safe state: this individual move is already complete.
      else
        problems << "source missing and matching target absent: #{move['source']}"
      end
    end

    target_metadata = Set.new
    Array(plan["entries"]).each do |entry|
      path = entry.fetch("metadata_target")
      problems << "duplicate metadata target in plan: #{path}" if target_metadata.include?(path)
      target_metadata << path
    end

    return if problems.empty?

    preview = problems.first(30).map { |problem| "  - #{problem}" }.join("\n")
    raise ArgumentError, "Apply preflight failed with #{problems.length} problems:\n#{preview}"
  end

  def backup_metadata!(plan, plan_root)
    backup_root = plan_root.join("metadata_backups")
    paths = Set.new(Array(plan["obsolete_metadata"]))
    Array(plan["entries"]).each { |entry| paths.merge(Array(entry["source_metadata_paths"])) }

    paths.each do |relative|
      source = absolute_from_shang(relative)
      next unless source.file?

      target = backup_root.join(relative)
      FileUtils.mkdir_p(target.dirname)
      FileUtils.cp(source, target)
    end
  end

  def backup_id_registry!(plan, plan_root)
    current = id_registry_sha256
    return if current == plan["updated_id_registry_sha256"]
    unless current == plan["id_registry_sha256"]
      raise ArgumentError, "ID registry is neither the reviewed original nor the reviewed updated file"
    end

    backup = plan_root.join("metadata_id_registry.before_shang_regionalisation.csv")
    if backup.file?
      unless sha256(backup) == plan["id_registry_sha256"]
        raise ArgumentError, "Existing ID-registry backup does not match the reviewed original: #{backup}"
      end
      return
    end
    FileUtils.cp(@id_registry_path, backup)
  end

  def install_updated_id_registry!(plan, plan_root)
    current = id_registry_sha256
    return if current == plan["updated_id_registry_sha256"]
    unless current == plan["id_registry_sha256"]
      raise ArgumentError, "ID registry changed during apply; refusing replacement"
    end

    reviewed = plan_root.join(plan.fetch("updated_id_registry_file"))
    unless reviewed.file? && sha256(reviewed) == plan.fetch("updated_id_registry_sha256")
      raise ArgumentError, "Reviewed updated ID registry is missing or changed: #{reviewed}"
    end

    temporary = @id_registry_path.dirname.join(".#{@id_registry_path.basename}.shang-#{Process.pid}.tmp")
    FileUtils.cp(reviewed, temporary)
    FileUtils.mv(temporary, @id_registry_path)
  ensure
    FileUtils.rm_f(temporary) if defined?(temporary) && temporary
  end

  def apply_move!(move)
    source = absolute_from_shang(move.fetch("source"))
    target = absolute_from_shang(move.fetch("target"))
    expected = move.fetch("sha256")

    if source.file?
      FileUtils.mkdir_p(target.dirname)
      if target.file?
        raise "Target differs despite preflight: #{target}" unless sha256(target) == expected
        FileUtils.rm_f(source)
      else
        FileUtils.mv(source, target)
      end
    elsif target.file? && sha256(target) == expected
      # Already applied before an interrupted run.
    else
      raise "Move source vanished after preflight: #{source}"
    end
  end

  def remove_empty_directories!
    protected = Set.new(Array(load_config["folder_skeleton"]).map { |parts| absolute_from_shang(Array(parts).join("/")).cleanpath.to_s })
    directories = @shang_root.glob("**/*").select(&:directory?).sort_by { |path| -path.to_s.length }

    directories.each do |directory|
      next if directory == @shang_root
      next if protected.include?(directory.cleanpath.to_s)
      next unless Dir.empty?(directory)

      Dir.rmdir(directory)
    rescue Errno::ENOTEMPTY, Errno::ENOENT
      next
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {
    config: ShangInscriptionRegionalisation::DEFAULT_CONFIG,
    concordances: "config/corpus_metadata/shang_oracle_concordances.csv",
    overrides: "config/corpus_metadata/shang_oracle_overrides.csv",
    id_registry: nil,
    output: "tmp/shang_inscription_regionalisation/plan_#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}",
    apply: false,
    reviewed_plan: nil,
    scope: "all",
    progress_every: ShangInscriptionRegionalisation::DEFAULT_PROGRESS_EVERY
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby script/shang_inscription_regionalisation.rb --shang-root PATH [options]"

    opts.on("--shang-root PATH", "Path to the current 商殷朝 folder (required)") { |value| options[:shang_root] = value }
    opts.on("--config PATH", "Authority/config YAML (default: #{options[:config]})") { |value| options[:config] = value }
    opts.on("--concordances PATH", "Reviewed cross-catalogue concordance CSV") { |value| options[:concordances] = value }
    opts.on("--overrides PATH", "Reviewed per-object geography/period override CSV") { |value| options[:overrides] = value }
    opts.on("--id-registry PATH", "Authoritative corpus-wide metadata_id_registry.csv (required)") { |value| options[:id_registry] = value }
    opts.on("--output PATH", "Dry-run output folder") { |value| options[:output] = value }
    opts.on("--scope SCOPE", "all, oracle_bones, or bronzes (default: all)") { |value| options[:scope] = value }
    opts.on("--progress-every N", Integer, "Print progress every N records") { |value| options[:progress_every] = value }
    opts.on("--reviewed-plan PATH", "Reviewed dry-run folder or migration_plan.json") { |value| options[:reviewed_plan] = value }
    opts.on("--apply", "Apply the exact reviewed plan") { options[:apply] = true }
    opts.on("-h", "--help", "Show this help") do
      puts opts
      exit 0
    end
  end

  parser.parse!
  raise OptionParser::MissingArgument, "--shang-root is required" unless options[:shang_root]

  begin
    ShangInscriptionRegionalisation.new(options).run
  rescue StandardError => error
    warn "[shang-regionalisation] ERROR: #{error.class}: #{error.message}"
    warn error.backtrace.first(10).map { |line| "[shang-regionalisation]   #{line}" }.join("\n") if ENV["DEBUG"] == "1"
    exit 1
  end
end
