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

# Repairs compilation documents which already have stable numeric IDs in the
# metadata registry but still fall back to path hashes because their work's
# metadata.json omitted direct document records.
#
# It also reconciles the duplicated physical witnesses of 全唐文 and 全唐詩,
# placing the compilation witnesses under Qing while retaining the older stable
# work/document IDs as the canonical IDs.  A normal run is read-only and writes
# a reviewed plan.  --apply rebuilds the plan from the live corpus, requires an
# exact match, stages every replacement, backs up every touched file, and rolls
# back on failure.
class CompilationFallbackRepair
  PLAN_VERSION = 1
  CSV_BOM = "\uFEFF"
  HEADER_PATTERN = /\A#\s*([A-Z][A-Z0-9_ ]{1,80})\s*[:：]\s*(.*?)\s*\z/
  LIST_SPLIT = /[;；|]/

  Result = Struct.new(:entries, :body, :body_sha256, :body_size, keyword_init: true)

  def initialize(options)
    @viewer_root = Pathname(options.fetch(:viewer_root)).expand_path
    @corpus_root = Pathname(options.fetch(:corpus_root)).expand_path
    @evidence_root = Pathname(options.fetch(:evidence_root)).expand_path
    @output_root = Pathname(options.fetch(:output_root)).expand_path
    @id_registry = options[:id_registry] ? Pathname(options[:id_registry]).expand_path : nil
    @apply = options.fetch(:apply)
    @progress_every = Integer(options.fetch(:progress_every))
    @started_at = Time.now.utc
  end

  def run
    validate_inputs!
    FileUtils.mkdir_p(@output_root)
    @id_registry ||= discover_registry
    raise ArgumentError, "No metadata_id_registry.csv found; pass --id-registry PATH" unless @id_registry&.file?

    if @apply
      reviewed = load_reviewed_plan
      current = build_plan
      unless plan_signature(reviewed) == plan_signature(current)
        write_json(@output_root.join("current_plan_after_mismatch.json"), current)
        raise "The live corpus no longer matches the reviewed plan. No changes were made. Review current_plan_after_mismatch.json."
      end
      raise "Reviewed plan is blocked; no changes were made" unless reviewed["ready_to_apply"]
      apply_plan(reviewed)
    else
      plan = build_plan
      write_plan(plan)
      print_summary(plan)
    end
  end

  def self.parse_legacy(raw)
    bytes = raw.to_s.b
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    raise Encoding::InvalidByteSequenceError, "invalid UTF-8" unless text.valid_encoding?

    text = text.delete_prefix("\uFEFF")
    lines = text.lines
    first = lines.index { |line| !line.match?(/\A[[:space:]]*\z/) }
    return Result.new(entries: [], body: text, body_sha256: Digest::SHA256.hexdigest(text.b), body_size: text.bytesize) unless first

    lines[first] = lines[first].delete_prefix("\uFEFF")
    unless lines[first].match?(HEADER_PATTERN)
      body = lines.join
      return Result.new(entries: [], body: body, body_sha256: Digest::SHA256.hexdigest(body.b), body_size: body.bytesize)
    end

    entries = []
    index = first
    while index < lines.length
      match = HEADER_PATTERN.match(lines[index].sub(/[\r\n]+\z/, ""))
      break unless match
      entries << [match[1].strip.upcase, match[2].strip]
      index += 1
    end
    index += 1 while index < lines.length && lines[index].match?(/\A[[:space:]]*\z/)
    body = lines[index..].to_a.join
    Result.new(entries: entries, body: body, body_sha256: Digest::SHA256.hexdigest(body.b), body_size: body.bytesize)
  end

  private

  def validate_inputs!
    raise ArgumentError, "Viewer root does not exist: #{@viewer_root}" unless @viewer_root.directory?
    raise ArgumentError, "Corpus root does not exist: #{@corpus_root}" unless @corpus_root.directory?
    %w[manifest.json files.csv registry_expected.csv structure.json].each do |name|
      path = @evidence_root.join(name)
      raise ArgumentError, "Evidence file is missing: #{path}" unless path.file?
    end
  end

  def discover_registry
    candidates = Dir.glob(@viewer_root.join("tmp/corpus_metadata_json/full_*/metadata_id_registry.csv").to_s)
      .map { |path| Pathname(path) }.select(&:file?)
    candidates.max_by { |path| [path.mtime.to_i, path.to_s] }
  end

  def load_reviewed_plan
    path = @output_root.join("plan.json")
    raise ArgumentError, "Reviewed plan is missing: #{path}. Run without --apply first." unless path.file?
    JSON.parse(path.read(encoding: "UTF-8"))
  end

  def build_plan
    verify_evidence!
    load_evidence!
    blocks = []
    verify_registry!(blocks)
    parsed = verify_and_parse_sources!(blocks)
    metadata_replacements = {}
    document_operations = []
    registry_changes = []
    work_aliases = []
    document_aliases = []

    build_ordinary_groups(parsed, metadata_replacements, document_operations, blocks)
    build_qtw(parsed, metadata_replacements, document_operations, registry_changes, work_aliases, document_aliases, blocks)
    build_qts(parsed, metadata_replacements, document_operations, registry_changes, work_aliases, document_aliases, blocks)
    build_chuci(parsed, metadata_replacements, document_operations, registry_changes, blocks)

    source_state = @file_rows.map do |row|
      {
        "path" => row.fetch("source_path"),
        "size_bytes" => row.fetch("size_bytes").to_i,
        "sha256" => row.fetch("sha256")
      }
    end

    plan = {
      "plan_version" => PLAN_VERSION,
      "created_at" => Time.now.utc.iso8601,
      "corpus_root" => @corpus_root.to_s,
      "id_registry" => @id_registry.to_s,
      "evidence_sha256" => evidence_digest,
      "source_state" => source_state,
      "metadata_replacements" => metadata_replacements,
      "document_operations" => document_operations,
      "registry_changes" => registry_changes,
      "work_aliases" => work_aliases,
      "document_aliases" => document_aliases,
      "blocks" => blocks,
      "ready_to_apply" => blocks.empty?,
      "summary" => {
        "source_documents" => @file_rows.length,
        "final_canonical_documents" => document_operations.count { |op| op["install"] },
        "documents_removed_as_exact_duplicates" => document_operations.count { |op| op["duplicate_alias"] },
        "metadata_files_replaced" => metadata_replacements.length,
        "registry_rows_changed" => registry_changes.length,
        "work_aliases" => work_aliases.length,
        "document_aliases" => document_aliases.length,
        "blocks" => blocks.length
      }
    }
    plan["signature"] = plan_signature(plan)
    plan
  end

  def verify_evidence!
    manifest = JSON.parse(@evidence_root.join("manifest.json").read(encoding: "UTF-8"))
    manifest.fetch("files").each do |entry|
      path = @evidence_root.join(entry.fetch("path"))
      raise "Evidence file missing: #{path}" unless path.file?
      actual = Digest::SHA256.file(path).hexdigest
      raise "Evidence checksum mismatch: #{path}" unless actual == entry.fetch("sha256")
    end
  end

  def evidence_digest
    Digest::SHA256.file(@evidence_root.join("manifest.json")).hexdigest
  end

  def load_evidence!
    @structure = JSON.parse(@evidence_root.join("structure.json").read(encoding: "UTF-8"))
    @file_rows = CSV.read(@evidence_root.join("files.csv"), headers: true, encoding: "bom|utf-8").map(&:to_h)
    @rows_by_group = @file_rows.group_by { |row| row.fetch("group_key") }
    @expected_registry_rows = CSV.read(@evidence_root.join("registry_expected.csv"), headers: true, encoding: "bom|utf-8").map(&:to_h)
    @expected_registry_by_key = @expected_registry_rows.to_h { |row| [[row.fetch("kind"), row.fetch("id")], row] }
    @base_metadata = {}
    @structure.fetch("base_metadata").each do |group, spec|
      path = @evidence_root.join(spec.fetch("file"))
      @base_metadata[group] = JSON.parse(path.read(encoding: "UTF-8"))
    end
  end

  def verify_registry!(blocks)
    @registry_headers = nil
    @registry_rows = []
    @registry_by_key = {}
    count = 0
    CSV.foreach(@id_registry, headers: true, encoding: "bom|utf-8") do |row|
      @registry_headers ||= row.headers
      hash = row.to_h
      key = [hash["kind"], hash["id"]]
      @registry_rows << hash
      @registry_by_key[key] = hash
      count += 1
      progress("registry rows read", count) if (count % 25_000).zero?
    end
    @registry_headers ||= %w[kind id identity_key path title parent_work_id source_document_id status]

    @expected_registry_by_key.each do |key, expected|
      actual = @registry_by_key[key]
      unless actual
        blocks << block("registry_row_missing", key.join(":"), expected, nil)
        next
      end
      fields = %w[kind id identity_key path title parent_work_id source_document_id status]
      mismatch = fields.any? { |field| actual[field].to_s != expected[field].to_s }
      blocks << block("registry_row_changed", key.join(":"), expected, actual) if mismatch
    end
  end

  def verify_and_parse_sources!(blocks)
    parsed = {}
    @file_rows.each_with_index do |row, index|
      rel = row.fetch("source_path")
      path = @corpus_root.join(rel)
      unless path.file?
        blocks << block("source_missing", rel, row, nil)
        next
      end
      size = path.size
      if size != row.fetch("size_bytes").to_i
        blocks << block("source_size_changed", rel, row.fetch("size_bytes").to_i, size)
        next
      end
      digest = Digest::SHA256.file(path).hexdigest
      if digest != row.fetch("sha256")
        blocks << block("source_sha_changed", rel, row.fetch("sha256"), digest)
        next
      end
      begin
        result = self.class.parse_legacy(path.binread)
        # The dry-run needs header metadata and body checksums, not 619 MB of
        # body strings held in memory at once. Apply mode reparses each source
        # while building the staged replacement.
        result.body = nil
        parsed[rel] = result
      rescue StandardError => error
        blocks << block("source_parse_error", rel, "valid UTF-8 legacy/body text", "#{error.class}: #{error.message}")
      end
      progress("source files verified", index + 1)
    end

    @structure.fetch("base_metadata").each do |group, spec|
      group_path = live_metadata_path(group)
      unless group_path.file?
        blocks << block("metadata_missing", group_path.to_s, spec.fetch("sha256"), nil)
        next
      end
      actual = Digest::SHA256.file(group_path).hexdigest
      blocks << block("metadata_changed", group_path.to_s, spec.fetch("sha256"), actual) unless actual == spec.fetch("sha256")
    end
    parsed
  end

  def live_metadata_path(group)
    if group.start_with?("orphan_")
      @corpus_root.join(@structure.fetch("chuci").fetch("root_path"), "metadata.json")
    else
      spec = @structure.fetch("canonical_groups")[group] rescue nil
      path = spec && spec["path"]
      path ||= @structure.fetch("qtw")[group == @structure.fetch("qtw").fetch("source_group") ? "source_path" : "target_path"] if [@structure.fetch("qtw").fetch("source_group"), @structure.fetch("qtw").fetch("duplicate_group")].include?(group)
      path ||= @structure.fetch("qts")[group == @structure.fetch("qts").fetch("subset_group") ? "source_path" : "target_path"] if [@structure.fetch("qts").fetch("subset_group"), @structure.fetch("qts").fetch("complete_group")].include?(group)
      @corpus_root.join(path, "metadata.json")
    end
  end

  def build_ordinary_groups(parsed, metadata_replacements, operations, blocks)
    @structure.fetch("canonical_groups").each do |group, spec|
      rows = @rows_by_group.fetch(group, [])
      docs = rows.sort_by { |row| row.fetch("document_id").to_i }.filter_map do |row|
        result = parsed[row.fetch("source_path")]
        next unless result
        final_path = row.fetch("source_path")
        operations << operation(row, result, final_path, install: true)
        build_document(row, result, final_path)
      end
      metadata = deep_copy(@base_metadata.fetch(group))
      metadata["work_id"] = spec.fetch("work_id")
      metadata["period"] = spec["period"] if spec["period"]
      metadata["polity"] = spec["polity"] if spec["polity"]
      metadata["documents"] = docs
      metadata_replacements[File.join(spec.fetch("path"), "metadata.json")] = metadata
      blocks << block("ordinary_document_count", group, rows.length, docs.length) unless docs.length == rows.length
    end
  end

  def build_qtw(parsed, metadata_replacements, operations, registry_changes, work_aliases, document_aliases, blocks)
    spec = @structure.fetch("qtw")
    source_rows = @rows_by_group.fetch(spec.fetch("source_group"), [])
    duplicate_rows = @rows_by_group.fetch(spec.fetch("duplicate_group"), [])
    source_by_volume = rows_by_volume(source_rows, "全唐文", blocks)
    duplicate_by_volume = rows_by_volume(duplicate_rows, "全唐文 duplicate", blocks)
    duplicate_volume = spec.fetch("duplicate_volume").to_i
    source = source_by_volume[duplicate_volume]
    duplicate = duplicate_by_volume[duplicate_volume]
    if source && duplicate && parsed[source["source_path"]] && parsed[duplicate["source_path"]]
      unless parsed[source["source_path"]].body_sha256 == parsed[duplicate["source_path"]].body_sha256
        blocks << block("qtw_duplicate_body_mismatch", duplicate_volume, parsed[source["source_path"]].body_sha256, parsed[duplicate["source_path"]].body_sha256)
      end
    else
      blocks << block("qtw_duplicate_volume_missing", duplicate_volume, "source and duplicate", nil)
    end

    docs = []
    source_by_volume.sort.each do |volume, row|
      result = parsed[row.fetch("source_path")]
      next unless result
      final_rel = File.join(spec.fetch("target_path"), format("全唐文__juan_%0#{spec.fetch('filename_width')}d.txt", volume))
      extra = volume == duplicate_volume && duplicate ? parsed[duplicate.fetch("source_path")] : nil
      operations << operation(row, result, final_rel, install: true, structural: "qtw")
      docs << build_document(row, result, final_rel, volume: volume, merge_result: extra)
      registry_changes << changed_registry_row(row.fetch("document_id"), path: final_rel, parent_work_id: spec.fetch("canonical_work_id"), status: "active", title: File.basename(final_rel, ".txt"))
    end

    if duplicate
      canonical_id = source&.fetch("document_id")
      final_rel = File.join(spec.fetch("target_path"), format("全唐文__juan_%0#{spec.fetch('filename_width')}d.txt", duplicate_volume))
      operations << operation(duplicate, parsed[duplicate.fetch("source_path")], final_rel, install: false, duplicate_alias: true, structural: "qtw") if parsed[duplicate.fetch("source_path")]
      alias_row = changed_registry_row(duplicate.fetch("document_id"), path: final_rel, parent_work_id: spec.fetch("canonical_work_id"), status: "alias", source_document_id: canonical_id, title: File.basename(final_rel, ".txt"))
      registry_changes << alias_row
      document_aliases << alias_summary(alias_row)
    end

    metadata = merge_work_metadata(@base_metadata.fetch(spec.fetch("source_group")), @base_metadata.fetch(spec.fetch("duplicate_group")))
    metadata["work_id"] = spec.fetch("canonical_work_id")
    metadata["period"] = spec.fetch("period")
    metadata["polity"] = spec.fetch("polity")
    metadata["documents"] = docs
    metadata_replacements[File.join(spec.fetch("target_path"), "metadata.json")] = metadata

    canonical_work = changed_registry_row(spec.fetch("canonical_work_id"), kind: "work", path: spec.fetch("target_path"), status: "active", title: spec.fetch("title"))
    alias_work = changed_registry_row(spec.fetch("alias_work_id"), kind: "work", path: spec.fetch("target_path"), parent_work_id: spec.fetch("canonical_work_id"), status: "alias", title: spec.fetch("title"))
    registry_changes.concat([canonical_work, alias_work])
    work_aliases << alias_summary(alias_work)
  end

  def build_qts(parsed, metadata_replacements, operations, registry_changes, work_aliases, document_aliases, blocks)
    spec = @structure.fetch("qts")
    subset_rows = @rows_by_group.fetch(spec.fetch("subset_group"), [])
    complete_rows = @rows_by_group.fetch(spec.fetch("complete_group"), [])
    subset = rows_by_volume(subset_rows, "全唐詩 subset", blocks)
    complete = rows_by_volume(complete_rows, "全唐詩 complete", blocks)
    missing = subset.keys - complete.keys
    blocks << block("qts_subset_volume_missing", missing.join(","), "all subset volumes in complete witness", nil) if missing.any?

    overlap = subset.keys & complete.keys
    overlap.each do |volume|
      left = parsed[subset.fetch(volume).fetch("source_path")]
      right = parsed[complete.fetch(volume).fetch("source_path")]
      next unless left && right
      blocks << block("qts_duplicate_body_mismatch", volume, left.body_sha256, right.body_sha256) unless left.body_sha256 == right.body_sha256
    end

    docs = []
    complete.sort.each do |volume, complete_row|
      result = parsed[complete_row.fetch("source_path")]
      next unless result
      subset_row = subset[volume]
      canonical_row = subset_row || complete_row
      canonical_id = canonical_row.fetch("document_id")
      final_rel = File.join(spec.fetch("target_path"), format("全唐詩__juan_%0#{spec.fetch('filename_width')}d.txt", volume))
      operations << operation(complete_row, result, final_rel, install: true, structural: "qts", canonical_document_id: canonical_id)
      merge_result = subset_row ? parsed[subset_row.fetch("source_path")] : nil
      docs << build_document(canonical_row, result, final_rel, volume: volume, merge_result: merge_result, document_id: canonical_id)
      registry_changes << changed_registry_row(canonical_id, path: final_rel, parent_work_id: spec.fetch("canonical_work_id"), status: "active", title: File.basename(final_rel, ".txt"))

      next unless subset_row
      alias_id = complete_row.fetch("document_id")
      alias_row = changed_registry_row(alias_id, path: final_rel, parent_work_id: spec.fetch("canonical_work_id"), status: "alias", source_document_id: canonical_id, title: File.basename(final_rel, ".txt"))
      registry_changes << alias_row
      document_aliases << alias_summary(alias_row)
      operations << operation(subset_row, parsed[subset_row.fetch("source_path")], final_rel, install: false, duplicate_alias: true, structural: "qts") if parsed[subset_row.fetch("source_path")]
    end

    metadata = merge_work_metadata(@base_metadata.fetch(spec.fetch("subset_group")), @base_metadata.fetch(spec.fetch("complete_group")))
    metadata["work_id"] = spec.fetch("canonical_work_id")
    metadata["period"] = spec.fetch("period")
    metadata["polity"] = spec.fetch("polity")
    metadata["documents"] = docs
    metadata_replacements[File.join(spec.fetch("target_path"), "metadata.json")] = metadata

    canonical_work = changed_registry_row(spec.fetch("canonical_work_id"), kind: "work", path: spec.fetch("target_path"), status: "active", title: spec.fetch("title"))
    alias_work = changed_registry_row(spec.fetch("alias_work_id"), kind: "work", path: spec.fetch("target_path"), parent_work_id: spec.fetch("canonical_work_id"), status: "alias", title: spec.fetch("title"))
    registry_changes.concat([canonical_work, alias_work])
    work_aliases << alias_summary(alias_work)
  end

  def build_chuci(parsed, metadata_replacements, operations, registry_changes, blocks)
    spec = @structure.fetch("chuci")
    metadata = deep_copy(@base_metadata.fetch("orphan_008"))
    documents = Array(metadata["documents"]).select { |doc| doc.is_a?(Hash) }
    spec.fetch("moves").each do |move|
      row = @rows_by_group.fetch(move.fetch("group_key"), []).first
      unless row
        blocks << block("chuci_source_row_missing", move.fetch("group_key"), "one row", nil)
        next
      end
      result = parsed[row.fetch("source_path")]
      next unless result
      final_rel = File.join(spec.fetch("root_path"), move.fetch("target_file"))
      operations << operation(row, result, final_rel, install: true, structural: "chuci")
      doc = build_document(row, result, final_rel, document_id: move.fetch("document_id"), explicit_title: move.fetch("title"))
      doc["work_title"] = move.fetch("work_title")
      doc["authors"] = move.fetch("authors")
      doc["geography_override"] = { "period" => move.fetch("period"), "polity" => move.fetch("polity") }
      documents.reject! { |existing| existing["document_id"].to_i == move.fetch("document_id").to_i }
      documents << doc
      registry_changes << changed_registry_row(move.fetch("document_id"), path: final_rel, parent_work_id: spec.fetch("work_id"), status: "active", title: move.fetch("title"))
    end
    metadata["documents"] = documents.sort_by { |doc| doc["document_id"].to_i }
    metadata_replacements[File.join(spec.fetch("root_path"), "metadata.json")] = metadata
  end

  def rows_by_volume(rows, label, blocks)
    result = {}
    rows.each do |row|
      volume = row.fetch("volume_number").to_i
      if volume <= 0
        blocks << block("volume_number_missing", row.fetch("source_path"), label, row.fetch("index_page_title"))
        next
      end
      if result.key?(volume)
        blocks << block("duplicate_volume_number", "#{label}:#{volume}", result[volume].fetch("source_path"), row.fetch("source_path"))
        next
      end
      result[volume] = row
    end
    result
  end

  def build_document(row, result, final_rel, volume: nil, merge_result: nil, document_id: nil, explicit_title: nil)
    entries = merge_entries(result.entries, merge_result&.entries)
    values = entries.each_with_object(Hash.new { |h, k| h[k] = [] }) { |(key, value), out| out[key] << value unless value.to_s.empty? }
    page_title = first(values["PAGE_TITLE"], row["index_page_title"])
    chapter = first(values["CHAPTER"], row["index_chapter"])
    display_title = first(values["DISPLAY_TITLE"], row["index_display_title"])
    title = explicit_title || first(display_title, page_title.to_s.split("/").last, chapter, File.basename(final_rel, ".txt"))
    authors = split_values(values["AUTHORS"] + values["AUTHOR"] + [row["index_author"]])
    categories = split_values(values["CATEGORY"] + values["CATEGORIES"])
    source_categories = split_values(values["WS_CATEGORIES"] + [row["index_categories"]])
    source_urls = (values["SOURCE_URL"] + values["URL"] + [row["index_source_url"]]).map(&:to_s).map(&:strip).reject(&:empty?).uniq

    known = Set.new(%w[
      TITLE PAGE_TITLE WORK_TITLE WORK_BASE_TITLE DISPLAY_TITLE AUTHOR AUTHORS DATE TIMES TIME NATION REGION
      CATEGORY CATEGORIES WS_CATEGORIES YEAR CHAPTER SOURCE_URL URL SCRAPED_AT_UTC
    ])
    legacy = {}
    values.each do |key, list|
      next if known.include?(key)
      clean = list.map(&:to_s).reject(&:empty?).uniq
      legacy[key] = clean.length == 1 ? clean.first : clean if clean.any?
    end
    nation = split_values(values["NATION"] + [row["index_nation"]])
    legacy["NATION"] = nation.length == 1 ? nation.first : nation if nation.any?

    compact_hash({
      "document_id" => (document_id || row.fetch("document_id")).to_i,
      "file" => File.basename(final_rel),
      "path" => final_rel,
      "title" => title,
      "page_title" => presence(page_title),
      "display_title" => presence(display_title),
      "chapter" => presence(chapter || (volume && "卷#{volume}")),
      "date_label" => first(values["DATE"], values["YEAR"]),
      "authors" => authors,
      "categories" => categories,
      "source_categories" => source_categories,
      "sources" => source_urls.map { |url| { "url" => url } },
      "scraped_at" => first(values["SCRAPED_AT_UTC"], row["index_scraped_at"]),
      "legacy_metadata" => legacy
    })
  end

  def merge_entries(first_entries, second_entries)
    (Array(first_entries) + Array(second_entries)).uniq
  end

  def merge_work_metadata(first_meta, second_meta)
    first = deep_copy(first_meta)
    second = deep_copy(second_meta)
    merged = first.merge(second) do |key, left, right|
      if left.is_a?(Array) || right.is_a?(Array)
        (Array(left) + Array(right)).uniq
      elsif left.is_a?(Hash) && right.is_a?(Hash)
        left.merge(right)
      elsif blank?(right)
        left
      else
        right
      end
    end
    merged["worklist"] = (Array(first_meta["worklist"]) + Array(second_meta["worklist"])).uniq
    merged["known_commentaries"] = (Array(first_meta["known_commentaries"]) + Array(second_meta["known_commentaries"])).uniq
    merged
  end

  def operation(row, result, final_rel, install:, duplicate_alias: false, structural: nil, canonical_document_id: nil)
    {
      "source_path" => row.fetch("source_path"),
      "source_sha256" => row.fetch("sha256"),
      "source_size_bytes" => row.fetch("size_bytes").to_i,
      "source_document_id" => row.fetch("document_id").to_i,
      "canonical_document_id" => (canonical_document_id || row.fetch("document_id")).to_i,
      "final_path" => final_rel,
      "body_sha256" => result.body_sha256,
      "body_size_bytes" => result.body_size,
      "install" => install,
      "duplicate_alias" => duplicate_alias,
      "structural" => structural
    }
  end

  def changed_registry_row(id, kind: "document", **changes)
    key = [kind, id.to_s]
    base = @registry_by_key[key]
    raise "Registry row not found for #{kind} #{id}" unless base
    row = base.dup
    changes.each { |field, value| row[field.to_s] = value.nil? ? "" : value.to_s }
    row
  end

  def alias_summary(row)
    {
      "kind" => row.fetch("kind"), "id" => row.fetch("id").to_i,
      "canonical_id" => (row["source_document_id"].to_s.empty? ? row["parent_work_id"].to_i : row["source_document_id"].to_i),
      "path" => row["path"], "title" => row["title"]
    }
  end

  def block(kind, subject, expected, actual)
    { "kind" => kind, "subject" => subject.to_s, "expected" => expected, "actual" => actual }
  end

  def write_plan(plan)
    write_json(@output_root.join("plan.json"), plan)
    write_json(@output_root.join("summary.json"), plan.fetch("summary").merge("ready_to_apply" => plan.fetch("ready_to_apply")))
    write_csv(@output_root.join("blocks.csv"), %w[kind subject expected actual], plan.fetch("blocks").map { |row| row.transform_values { |v| json_cell(v) } })
    write_csv(@output_root.join("work_id_aliases.csv"), %w[kind id canonical_id path title], plan.fetch("work_aliases"))
    write_csv(@output_root.join("document_id_aliases.csv"), %w[kind id canonical_id path title], plan.fetch("document_aliases"))
    write_csv(@output_root.join("registry_changes.csv"), @registry_headers, plan.fetch("registry_changes"))
  end

  def print_summary(plan)
    summary = plan.fetch("summary")
    warn "[fallback-repair] source documents: #{summary['source_documents']}"
    warn "[fallback-repair] final canonical documents: #{summary['final_canonical_documents']}"
    warn "[fallback-repair] exact duplicates removed: #{summary['documents_removed_as_exact_duplicates']}"
    warn "[fallback-repair] work aliases: #{summary['work_aliases']}"
    warn "[fallback-repair] document aliases: #{summary['document_aliases']}"
    warn "[fallback-repair] blocks: #{summary['blocks']}"
    warn "[fallback-repair] ready_to_apply=#{plan['ready_to_apply']}"
    warn "[fallback-repair] review #{@output_root.join('plan.json')}"
  end

  def apply_plan(plan)
    timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    backup_root = @output_root.join("backups", timestamp)
    staging_root = @output_root.join("staging", timestamp)
    FileUtils.rm_rf(staging_root)
    FileUtils.mkdir_p(staging_root)

    operations = plan.fetch("document_operations")
    metadata_replacements = plan.fetch("metadata_replacements")
    changed_registry = plan.fetch("registry_changes")

    warn "[fallback-repair] staging body-only files"
    operations.select { |op| op.fetch("install") }.each_with_index do |op, index|
      source = @corpus_root.join(op.fetch("source_path"))
      result = self.class.parse_legacy(source.binread)
      raise "Body changed while staging #{op['source_path']}" unless result.body_sha256 == op.fetch("body_sha256")
      target = staging_root.join("corpus", op.fetch("final_path"))
      FileUtils.mkdir_p(target.dirname)
      target.binwrite(result.body)
      raise "Staged body verification failed #{target}" unless Digest::SHA256.file(target).hexdigest == op.fetch("body_sha256")
      progress("body files staged", index + 1)
    end

    metadata_replacements.each do |rel, payload|
      target = staging_root.join("corpus", rel)
      FileUtils.mkdir_p(target.dirname)
      target.write(JSON.pretty_generate(payload) + "\n", encoding: "UTF-8")
    end

    staged_registry = staging_root.join("metadata_id_registry.csv")
    change_map = changed_registry.to_h { |row| [[row.fetch("kind"), row.fetch("id")], row] }
    CSV.open(staged_registry, "wb", encoding: "UTF-8") do |csv|
      csv << @registry_headers
      @registry_rows.each do |row|
        replacement = change_map[[row.fetch("kind"), row.fetch("id")]] || row
        csv << @registry_headers.map { |header| replacement[header] }
      end
    end

    backup_paths = Set.new
    operations.each { |op| backup_paths << op.fetch("source_path") }
    metadata_replacements.each_key { |rel| backup_paths << rel }
    structural_dirs = structural_directories
    structural_dirs.each do |dir|
      root = @corpus_root.join(dir)
      next unless root.directory?
      Dir.glob(root.join("**/*").to_s, File::FNM_DOTMATCH).each do |path|
        next if [".", ".."].include?(File.basename(path))
        p = Pathname(path)
        backup_paths << p.relative_path_from(@corpus_root).to_s if p.file?
      end
    end

    warn "[fallback-repair] backing up #{backup_paths.length} corpus files"
    backup_paths.each_with_index do |rel, index|
      source = @corpus_root.join(rel)
      next unless source.file?
      destination = backup_root.join("corpus", rel)
      FileUtils.mkdir_p(destination.dirname)
      hardlink_or_copy(source, destination)
      progress("backup files", index + 1)
    end
    FileUtils.mkdir_p(backup_root)
    FileUtils.cp(@id_registry, backup_root.join("metadata_id_registry.csv"))

    final_new_paths = operations.select { |op| op.fetch("install") }.map { |op| op.fetch("final_path") }.to_set
    begin
      structural_dirs.each { |rel| FileUtils.rm_rf(@corpus_root.join(rel)) }

      # Install the two rebuilt Qing compilation directories first.
      [@structure.fetch("qtw").fetch("target_path"), @structure.fetch("qts").fetch("target_path")].each do |rel|
        staged = staging_root.join("corpus", rel)
        target = @corpus_root.join(rel)
        FileUtils.mkdir_p(target.dirname)
        FileUtils.mv(staged, target)
      end

      # Install ordinary and 楚辭 documents not already inside the rebuilt dirs.
      operations.select { |op| op.fetch("install") }.each_with_index do |op, index|
        rel = op.fetch("final_path")
        next if rel.start_with?(@structure.fetch("qtw").fetch("target_path") + "/")
        next if rel.start_with?(@structure.fetch("qts").fetch("target_path") + "/")
        staged = staging_root.join("corpus", rel)
        target = @corpus_root.join(rel)
        FileUtils.mkdir_p(target.dirname)
        atomic_replace(staged, target)
        progress("body files installed", index + 1)
      end

      # Remove moved 楚辭 source paths when the destination differs.
      operations.select { |op| op["structural"] == "chuci" }.each do |op|
        old = @corpus_root.join(op.fetch("source_path"))
        old.delete if old.file? && op.fetch("source_path") != op.fetch("final_path")
      end

      metadata_replacements.each do |rel, _payload|
        next if rel.start_with?(@structure.fetch("qtw").fetch("target_path") + "/")
        next if rel.start_with?(@structure.fetch("qts").fetch("target_path") + "/")
        staged = staging_root.join("corpus", rel)
        target = @corpus_root.join(rel)
        FileUtils.mkdir_p(target.dirname)
        atomic_replace(staged, target)
      end

      atomic_replace(staged_registry, @id_registry)
      verify_final!(plan)
      write_json(@output_root.join("apply_summary.json"), plan.fetch("summary").merge(
        "applied_at" => Time.now.utc.iso8601,
        "backup_root" => backup_root.to_s,
        "success" => true
      ))
      warn "[fallback-repair] SUCCESS"
      warn "[fallback-repair] backup retained at #{backup_root}"
      warn "[fallback-repair] next: rebuild the corpus-search manifest"
    rescue StandardError => error
      warn "[fallback-repair] ERROR: #{error.class}: #{error.message}; rolling back"
      rollback!(backup_root, backup_paths, final_new_paths, structural_dirs)
      raise
    ensure
      FileUtils.rm_rf(staging_root)
    end
  end

  def structural_directories
    [
      @structure.fetch("qtw").fetch("source_path"),
      @structure.fetch("qtw").fetch("target_path"),
      @structure.fetch("qts").fetch("source_path"),
      @structure.fetch("qts").fetch("target_path")
    ].uniq
  end

  def verify_final!(plan)
    plan.fetch("document_operations").select { |op| op.fetch("install") }.each_with_index do |op, index|
      path = @corpus_root.join(op.fetch("final_path"))
      raise "Final file missing: #{path}" unless path.file?
      actual = Digest::SHA256.file(path).hexdigest
      raise "Final body mismatch: #{path}" unless actual == op.fetch("body_sha256")
      progress("final files verified", index + 1)
    end
    plan.fetch("metadata_replacements").each do |rel, payload|
      path = @corpus_root.join(rel)
      actual = JSON.parse(path.read(encoding: "UTF-8"))
      raise "Final metadata mismatch: #{path}" unless actual == payload
    end

    final_registry = {}
    CSV.foreach(@id_registry, headers: true, encoding: "bom|utf-8") do |row|
      hash = row.to_h
      final_registry[[hash.fetch("kind"), hash.fetch("id")]] = hash
    end
    plan.fetch("registry_changes").each do |expected|
      key = [expected.fetch("kind"), expected.fetch("id")]
      actual = final_registry[key]
      raise "Final registry row missing: #{key.join(':')}" unless actual
      fields = %w[kind id identity_key path title parent_work_id source_document_id status]
      mismatch = fields.any? { |field| actual[field].to_s != expected[field].to_s }
      raise "Final registry row mismatch: #{key.join(':')}" if mismatch
    end
  end

  def rollback!(backup_root, backup_paths, final_new_paths, structural_dirs)
    structural_dirs.each { |rel| FileUtils.rm_rf(@corpus_root.join(rel)) }
    final_new_paths.each do |rel|
      path = @corpus_root.join(rel)
      path.delete if path.file?
    rescue SystemCallError
      nil
    end
    backup_paths.each do |rel|
      backup = backup_root.join("corpus", rel)
      next unless backup.file?
      target = @corpus_root.join(rel)
      FileUtils.mkdir_p(target.dirname)
      FileUtils.cp(backup, target, preserve: true)
    end
    registry_backup = backup_root.join("metadata_id_registry.csv")
    FileUtils.cp(registry_backup, @id_registry) if registry_backup.file?
  end

  def hardlink_or_copy(source, destination)
    File.link(source, destination)
  rescue SystemCallError
    FileUtils.cp(source, destination, preserve: true)
  end

  def atomic_replace(source, target)
    temp = target.dirname.join(".#{target.basename}.repair-#{Process.pid}-#{rand(1_000_000)}")
    FileUtils.cp(source, temp)
    target.delete if target.file?
    File.rename(temp, target)
  ensure
    temp&.delete if temp&.file?
  end

  def plan_signature(plan)
    payload = {
      "plan_version" => plan["plan_version"],
      "evidence_sha256" => plan["evidence_sha256"],
      "source_state" => plan["source_state"],
      "metadata_replacements" => plan["metadata_replacements"],
      "document_operations" => plan["document_operations"],
      "registry_changes" => plan["registry_changes"],
      "work_aliases" => plan["work_aliases"],
      "document_aliases" => plan["document_aliases"],
      "blocks" => plan["blocks"],
      "ready_to_apply" => plan["ready_to_apply"]
    }
    Digest::SHA256.hexdigest(JSON.generate(payload))
  end

  def write_json(path, value)
    FileUtils.mkdir_p(path.dirname)
    path.write(JSON.pretty_generate(value) + "\n", encoding: "UTF-8")
  end

  def write_csv(path, headers, rows)
    FileUtils.mkdir_p(path.dirname)
    CSV.open(path, "wb", encoding: "UTF-8") do |csv|
      csv << headers
      rows.each { |row| csv << headers.map { |header| row[header] || row[header.to_sym] } }
    end
  end

  def progress(label, count)
    return unless @progress_every.positive?
    return unless (count % @progress_every).zero?
    warn "[fallback-repair] #{label}: #{count} (elapsed #{(Time.now.utc - @started_at).round(1)}s)"
  end

  def split_values(values)
    Array(values).flat_map { |value| value.to_s.split(LIST_SPLIT) }.map(&:strip).reject(&:empty?).uniq
  end

  def first(*values)
    values.flatten.find { |value| !blank?(value) }
  end

  def presence(value)
    blank?(value) ? nil : value
  end

  def blank?(value)
    value.nil? || value == false || (value.respond_to?(:empty?) && value.empty?) || value.to_s.strip.empty?
  end

  def compact_hash(hash)
    hash.each_with_object({}) do |(key, value), out|
      next if blank?(value)
      out[key] = value
    end
  end

  def deep_copy(value)
    JSON.parse(JSON.generate(value))
  end

  def json_cell(value)
    value.is_a?(String) ? value : JSON.generate(value)
  end
end

if $PROGRAM_NAME == __FILE__
  script_root = Pathname(__dir__).expand_path
  viewer_root = script_root.parent
  options = {
    viewer_root: viewer_root,
    corpus_root: viewer_root.parent.join("corpus"),
    evidence_root: viewer_root.join("config/corpus_metadata/fallback_compilation_repair"),
    output_root: viewer_root.join("tmp/compilation_fallback_repair"),
    id_registry: nil,
    apply: false,
    progress_every: 500
  }

  OptionParser.new do |parser|
    parser.banner = "Usage: ruby script/repair_compilation_fallback_metadata.rb [options]"
    parser.on("--corpus-root PATH") { |value| options[:corpus_root] = Pathname(value) }
    parser.on("--evidence-root PATH") { |value| options[:evidence_root] = Pathname(value) }
    parser.on("--output PATH") { |value| options[:output_root] = Pathname(value) }
    parser.on("--id-registry PATH") { |value| options[:id_registry] = Pathname(value) }
    parser.on("--progress-every N", Integer) { |value| options[:progress_every] = value }
    parser.on("--apply") { options[:apply] = true }
  end.parse!

  CompilationFallbackRepair.new(options).run
end
