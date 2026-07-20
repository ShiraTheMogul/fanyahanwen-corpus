#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "time"
require "unicode_normalize/normalize"
require "yaml"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

module RepairWikiCleanLayout
  module_function

  EXPECTED_HEADER_KEYS = %w[
    WORK_TITLE
    DISPLAY_TITLE
    AUTHOR
    TIMES
    PAGE_TITLE
    CATEGORIES
  ].freeze

  EXPECTED_WORKFLOW_RULES = {
    "WORK_TITLE" => { "target" => "title", "level" => "work", "type" => "scalar" },
    "DISPLAY_TITLE" => { "target" => "display_title", "level" => "document", "type" => "scalar" },
    "AUTHOR" => { "target" => "authors", "level" => "work", "type" => "list" },
    "TIMES" => { "target" => "geography", "level" => "auto", "type" => "geography" },
    "PAGE_TITLE" => { "target" => "page_title", "level" => "document", "type" => "scalar" },
    "CATEGORIES" => { "target" => "categories", "level" => "work", "type" => "list" }
  }.freeze

  GEOGRAPHY_FIELDS = %w[corpus_root macro_region period polity region].freeze
  RETRYABLE_ERRORS = [Errno::EIO, Errno::EACCES, Errno::EPERM, Errno::EBUSY].freeze

  Options = Struct.new(
    :apply,
    :corpus_root,
    :viewer_root,
    :output_root,
    :progress_every,
    :max_files,
    keyword_init: true
  )

  PlanRow = Struct.new(
    :title,
    :source_path,
    :target_path,
    :metadata_path,
    :work_id,
    :document_id,
    :old_document_path,
    :new_document_path,
    :header_status,
    :header_values,
    :header_line_values,
    :source_sha256,
    :body_sha256,
    :target_status,
    :action,
    :blocker,
    :message,
    :metadata,
    :updated_metadata,
    :document_record,
    :body,
    :merge_operations,
    :metadata_conflicts,
    keyword_init: true
  )

  def run(argv)
    started_at = Time.now.utc
    options = parse_options(argv)
    viewer_root = Pathname.new(options.viewer_root || Dir.pwd).expand_path
    corpus_root = Pathname.new(options.corpus_root || "../corpus").expand_path
    clean_root = corpus_root.join("維基大典", "clean")
    abort_with("Missing 維基大典 clean root: #{clean_root}") unless clean_root.directory?

    workflow = load_workflow!(viewer_root)

    output_root = Pathname.new(
      options.output_root ||
      File.join("tmp", "wiki_clean_layout_repair", started_at.strftime("%Y%m%dT%H%M%SZ"))
    ).expand_path
    FileUtils.mkdir_p(output_root)

    puts "=" * 78
    puts "維基大典 JSON + LAYOUT MIGRATION — #{options.apply ? 'APPLY' : 'DRY RUN'}"
    puts "=" * 78
    puts "Viewer root: #{viewer_root}"
    puts "Corpus root: #{corpus_root}"
    puts "Target root: #{clean_root}"
    puts "Output:      #{output_root}"
    puts
    puts "Validated against current JSON workflow:"
    EXPECTED_HEADER_KEYS.each do |key|
      rule = workflow.fetch(:key_rules).fetch(key)
      puts "  #{key.ljust(14)} -> #{rule.fetch('level')}.#{rule.fetch('target')} (#{rule.fetch('type')})"
    end
    puts

    flat_texts = with_retry("enumerate flat texts") do
      clean_root.children.select(&:file?).select { |path| path.extname.casecmp(".txt").zero? }.sort_by(&:to_s)
    end
    if options.max_files
      abort_with("--max-files is dry-run only") if options.apply
      flat_texts = flat_texts.first(options.max_files)
    end

    puts "Flat TXT files selected: #{flat_texts.length}"
    puts

    rows = []
    flat_texts.each_with_index do |source_path, index|
      rows << inspect_one(corpus_root, clean_root, source_path, workflow)
      if ((index + 1) % options.progress_every).zero? || index + 1 == flat_texts.length
        elapsed = Time.now.utc - started_at
        blockers = rows.count { |row| row.blocker }
        conflicts = rows.sum { |row| Array(row.metadata_conflicts).length }
        additions = rows.sum { |row| Array(row.merge_operations).count { |op| op["action"] == "add" } }
        repairs = rows.sum { |row| Array(row.merge_operations).count { |op| op["action"] == "repair_legacy_header_bleed" } }
        puts format("[%s] inspected %d / %d | blockers: %d | metadata conflicts: %d | additions: %d | repairs: %d | elapsed: %.1fs",
                    Time.now.utc.iso8601, index + 1, flat_texts.length, blockers, conflicts, additions, repairs, elapsed)
      end
    end

    mark_duplicate_ids!(rows, :work_id, "duplicate_work_id")
    mark_duplicate_ids!(rows, :document_id, "duplicate_document_id")
    write_plan_reports(output_root, rows, options, started_at)

    blockers = rows.select(&:blocker)
    if blockers.any?
      warn
      warn "BLOCKED: #{blockers.length} item(s) require review. Nothing was changed."
      warn "See: #{output_root.join('blockers.csv')}"
      warn "Metadata conflicts: #{output_root.join('metadata_conflicts.csv')}"
      return 2
    end

    unless options.apply
      puts
      puts "Dry run complete. Nothing was changed."
      puts "Review summary.txt, metadata_merge.csv, and metadata_conflicts.csv."
      puts "Only rerun with --apply when blockers and metadata conflicts are both zero."
      return 0
    end

    backup_root = output_root.join("backup")
    FileUtils.mkdir_p(backup_root)
    apply_log = []

    rows.each_with_index do |row, index|
      apply_one(corpus_root, row, backup_root)
      apply_log << {
        "source_path" => row.source_path.to_s,
        "target_path" => row.target_path.to_s,
        "metadata_path" => row.metadata_path.to_s,
        "work_id" => row.work_id,
        "document_id" => row.document_id,
        "metadata_fields_added" => row.merge_operations.count { |op| op["action"] == "add" },
        "metadata_fields_confirmed" => row.merge_operations.count { |op| op["action"] == "already_present" },
        "metadata_fields_repaired" => row.merge_operations.count { |op| op["action"] == "repair_legacy_header_bleed" },
        "status" => "applied"
      }
      if ((index + 1) % options.progress_every).zero? || index + 1 == rows.length
        puts format("[%s] applied %d / %d", Time.now.utc.iso8601, index + 1, rows.length)
      end
    end

    write_csv(output_root.join("apply_log.csv"), apply_log)
    verify_all!(corpus_root, rows, workflow)

    finished_at = Time.now.utc
    summary = {
      "version" => 3,
      "mode" => "apply",
      "started_at" => started_at.iso8601,
      "finished_at" => finished_at.iso8601,
      "elapsed_seconds" => (finished_at - started_at).round(3),
      "selected_files" => rows.length,
      "moved_or_reconciled" => rows.length,
      "headers_removed" => rows.count { |row| row.header_status == "full_legacy_header" },
      "metadata_values_added" => rows.sum { |row| row.merge_operations.count { |op| op["action"] == "add" } },
      "metadata_values_confirmed" => rows.sum { |row| row.merge_operations.count { |op| op["action"] == "already_present" } },
      "metadata_values_repaired" => rows.sum { |row| row.merge_operations.count { |op| op["action"] == "repair_legacy_header_bleed" } },
      "blank_header_values_ignored" => rows.sum { |row| row.merge_operations.count { |op| op["action"] == "blank_ignored" } },
      "metadata_conflicts" => 0,
      "work_ids_preserved" => rows.map(&:work_id).uniq.length,
      "document_ids_preserved" => rows.map(&:document_id).uniq.length,
      "backup_root" => backup_root.to_s,
      "verification" => "passed"
    }
    atomic_write(output_root.join("apply_summary.json"), JSON.pretty_generate(summary) + "\n")

    puts
    puts "APPLY COMPLETE"
    puts "Files repaired:             #{rows.length}"
    puts "Header values added to JSON: #{summary['metadata_values_added']}"
    puts "Header values already there: #{summary['metadata_values_confirmed']}"
    puts "Old JSON artefacts repaired: #{summary['metadata_values_repaired']}"
    puts "Backup:                     #{backup_root}"
    puts "Verification:               PASSED"
    puts
    puts "Next commands:"
    puts "  bin/rails corpus_search:rebuild_manifest"
    puts "  ruby script/project_state_audit.rb --corpus-root ../corpus --scope '維基大典/clean' --output tmp/project_state_audit/wiki_clean_post_repair"
    puts "  ruby script/verify_unicode_integrity.rb"
    0
  rescue Interrupt
    warn "\nInterrupted. Any completed item has its original TXT and metadata in the output backup directory."
    130
  end

  def parse_options(argv)
    options = Options.new(apply: false, progress_every: 1_000)
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby script/repair_wiki_clean_layout.rb [options]"
      opts.on("--dry-run", "Inspect and write a plan without changing files (default)") { options.apply = false }
      opts.on("--apply", "Apply the fully validated JSON + layout migration") { options.apply = true }
      opts.on("--corpus-root PATH", "Corpus root; defaults to ../corpus") { |value| options.corpus_root = value }
      opts.on("--viewer-root PATH", "Viewer root containing config/corpus_metadata; defaults to current directory") { |value| options.viewer_root = value }
      opts.on("--output PATH", "Report and backup directory") { |value| options.output_root = value }
      opts.on("--progress-every N", Integer, "Progress interval; default 1000") do |value|
        abort_with("--progress-every must be positive") unless value.positive?
        options.progress_every = value
      end
      opts.on("--max-files N", Integer, "Dry-run only: inspect the first N flat files") do |value|
        abort_with("--max-files must be positive") unless value.positive?
        options.max_files = value
      end
      opts.on("-h", "--help", "Show help") do
        puts opts
        exit 0
      end
    end
    parser.parse!(argv)
    abort_with("Unexpected arguments: #{argv.join(' ')}") unless argv.empty?
    options
  end

  def load_workflow!(viewer_root)
    generation_path = viewer_root.join("config", "corpus_metadata", "json_generation_map.yml")
    geography_path = viewer_root.join("config", "corpus_metadata", "geography_period_map.yml")
    abort_with("Missing JSON generation map: #{generation_path}") unless generation_path.file?
    abort_with("Missing geography mapping: #{geography_path}") unless geography_path.file?

    generation = YAML.safe_load(generation_path.read(encoding: "UTF-8"), permitted_classes: [], aliases: false) || {}
    geography = YAML.safe_load(geography_path.read(encoding: "UTF-8"), permitted_classes: [], aliases: false) || {}
    key_rules = generation.fetch("keys", {})

    EXPECTED_WORKFLOW_RULES.each do |key, expected|
      actual = key_rules[key]
      abort_with("Current JSON workflow has no rule for #{key}") unless actual.is_a?(Hash)
      expected.each do |field, value|
        unless actual[field].to_s == value
          abort_with("JSON workflow rule changed for #{key}. Expected #{field}=#{value.inspect}, found #{actual[field].inspect}. Refusing to guess.")
        end
      end
    end

    separators = generation.fetch("list_separators", "[，、；;,|＆&]")
    begin
      list_pattern = Regexp.new(separators)
    rescue RegexpError => error
      abort_with("Invalid list separator regex in JSON workflow: #{error.message}")
    end

    {
      generation_path: generation_path,
      geography_path: geography_path,
      generation: generation,
      geography: geography,
      key_rules: key_rules,
      list_pattern: list_pattern
    }
  end

  def inspect_one(corpus_root, clean_root, source_path, workflow)
    title = source_path.basename(".txt").to_s
    work_dir = clean_root.join(title)
    metadata_path = work_dir.join("metadata.json")
    target_path = work_dir.join(source_path.basename)
    source_relative = relative(corpus_root, source_path)
    target_relative = relative(corpus_root, target_path)

    row = PlanRow.new(
      title: title,
      source_path: source_path,
      target_path: target_path,
      metadata_path: metadata_path,
      old_document_path: source_relative,
      new_document_path: target_relative,
      header_values: {},
      header_line_values: {},
      merge_operations: [],
      metadata_conflicts: []
    )

    unless work_dir.directory?
      return block(row, "missing_same_named_directory", "Missing same-named work directory: #{work_dir}")
    end
    unless metadata_path.file?
      return block(row, "missing_metadata", "Missing metadata.json: #{metadata_path}")
    end

    metadata = read_json(metadata_path)
    unless metadata.is_a?(Hash)
      return block(row, "metadata_not_mapping", "metadata.json is not a JSON object")
    end
    row.metadata = metadata
    row.work_id = integer_id(metadata["work_id"])
    return block(row, "missing_numeric_work_id", "metadata.json has no numeric work_id") unless row.work_id

    matches = document_records(metadata).select do |record|
      record_path = record["path"].to_s.tr("\\", "/")
      record_file = record["file"].to_s
      [source_relative, target_relative].include?(record_path) || (record_path.empty? && record_file == source_path.basename.to_s)
    end
    if matches.empty?
      file_matches = document_records(metadata).select { |record| record["file"].to_s == source_path.basename.to_s }
      matches = file_matches if file_matches.length == 1
    end
    if matches.empty?
      return block(row, "metadata_document_missing", "No metadata document record identifies #{source_relative} or #{target_relative}")
    end
    if matches.length > 1
      return block(row, "metadata_document_ambiguous", "Multiple metadata document records identify this TXT")
    end

    record = matches.first
    row.document_record = record
    row.document_id = integer_id(record["document_id"])
    return block(row, "missing_numeric_document_id", "Document record has no numeric document_id") unless row.document_id

    source_bytes = with_retry("read #{source_path}") { source_path.binread }
    source_text = source_bytes.dup.force_encoding(Encoding::UTF_8)
    return block(row, "invalid_utf8", "Source TXT is not valid UTF-8") unless source_text.valid_encoding?

    header = parse_leading_legacy_header(source_text)
    row.header_status = header.fetch(:status)
    if header[:status] == "partial_legacy_header"
      return block(row, "partial_legacy_header", header.fetch(:message))
    end
    unless header[:status] == "full_legacy_header"
      return block(row, "legacy_header_missing", "Expected the six-key legacy header before migration")
    end

    row.header_values = header.fetch(:values)
    row.header_line_values = header.fetch(:line_values)
    row.body = header.fetch(:body)
    row.source_sha256 = Digest::SHA256.hexdigest(source_bytes)
    row.body_sha256 = Digest::SHA256.hexdigest(row.body.encode(Encoding::UTF_8))

    updated_metadata, operations, conflicts = merge_header_into_metadata(
      metadata: metadata,
      document_id: row.document_id,
      header_values: row.header_values,
      header_line_values: row.header_line_values,
      workflow: workflow
    )
    row.merge_operations = operations
    row.metadata_conflicts = conflicts
    if conflicts.any?
      message = conflicts.first(3).map { |item| "#{item['source_key']} -> #{item['target']}: #{item['message']}" }.join("; ")
      return block(row, "metadata_conflict", message)
    end

    updated_record = document_records(updated_metadata).find { |item| integer_id(item["document_id"]) == row.document_id }
    return block(row, "updated_document_missing", "Could not find document record after metadata merge") unless updated_record
    updated_record["file"] = source_path.basename.to_s
    updated_record["path"] = target_relative
    updated_record["body_start_line"] = 1
    row.updated_metadata = updated_metadata

    if target_path.exist?
      return block(row, "target_not_file", "Target exists but is not a file: #{target_path}") unless target_path.file?
      target_bytes = with_retry("read existing target #{target_path}") { target_path.binread }
      target_text = target_bytes.dup.force_encoding(Encoding::UTF_8)
      return block(row, "target_invalid_utf8", "Existing target is not valid UTF-8") unless target_text.valid_encoding?
      target_parsed = parse_leading_legacy_header(target_text)
      unless [target_text, target_parsed[:body]].include?(row.body)
        return block(row, "different_target_collision", "Existing target differs from the source body")
      end
      row.target_status = target_text == row.body ? "already_body_only" : "same_content_needs_header_cleanup"
      row.action = "reconcile_existing_target"
    else
      row.target_status = "absent"
      row.action = "move_into_work_folder"
    end

    additions = operations.count { |op| op["action"] == "add" }
    confirmed = operations.count { |op| op["action"] == "already_present" }
    blanks = operations.count { |op| op["action"] == "blank_ignored" }
    repairs = operations.count { |op| op["action"] == "repair_legacy_header_bleed" }
    row.message = "Validated; preserve IDs; add #{additions} JSON value(s), confirm #{confirmed}, repair #{repairs} old parser artefact(s), ignore #{blanks} blank header value(s)."
    row
  rescue JSON::ParserError => error
    block(row, "invalid_metadata_json", error.message)
  rescue StandardError => error
    block(row, "inspection_error", "#{error.class}: #{error.message}")
  end

  def merge_header_into_metadata(metadata:, document_id:, header_values:, header_line_values:, workflow:)
    updated = deep_copy(metadata)
    document = document_records(updated).find { |item| integer_id(item["document_id"]) == document_id }
    raise "Document #{document_id} disappeared during metadata merge" unless document

    operations = []
    conflicts = []

    merge_scalar!(updated, "title", header_values["WORK_TITLE"],
                  source_key: "WORK_TITLE", scope: "work", operations: operations, conflicts: conflicts,
                  legacy_line_value: header_line_values["WORK_TITLE"])
    merge_scalar!(document, "display_title", header_values["DISPLAY_TITLE"],
                  source_key: "DISPLAY_TITLE", scope: "document", operations: operations, conflicts: conflicts,
                  legacy_line_value: header_line_values["DISPLAY_TITLE"])
    merge_list!(updated, "authors", header_values["AUTHOR"], workflow.fetch(:list_pattern),
                source_key: "AUTHOR", scope: "work", operations: operations, conflicts: conflicts, compare_names: true)
    merge_times!(updated, header_values["TIMES"], workflow,
                 operations: operations, conflicts: conflicts,
                 legacy_line_value: header_line_values["TIMES"])
    merge_scalar!(document, "page_title", header_values["PAGE_TITLE"],
                  source_key: "PAGE_TITLE", scope: "document", operations: operations, conflicts: conflicts,
                  legacy_line_value: header_line_values["PAGE_TITLE"])
    merge_list!(updated, "categories", header_values["CATEGORIES"], workflow.fetch(:list_pattern),
                source_key: "CATEGORIES", scope: "work", operations: operations, conflicts: conflicts)

    [updated, operations, conflicts]
  end

  def merge_times!(metadata, raw_value, workflow, operations:, conflicts:, legacy_line_value: nil)
    value = clean_scalar(raw_value)
    if value.empty?
      operations << operation_row("TIMES", "work", "geography", raw_value, nil, nil, "blank_ignored", "Blank legacy value")
      return
    end

    if date_like?(value)
      merge_scalar!(metadata, "date_label", value,
                    source_key: "TIMES", scope: "work", operations: operations, conflicts: conflicts,
                    legacy_line_value: legacy_line_value)
      return
    end

    geography = geography_for_times(value, workflow.fetch(:geography))
    geography.each do |field, mapped_value|
      next unless GEOGRAPHY_FIELDS.include?(field)
      merge_scalar!(metadata, field, mapped_value,
                    source_key: "TIMES", scope: "work", operations: operations, conflicts: conflicts,
                    target_label: "#{field}")
    end
  end

  def geography_for_times(value, geography_map)
    explicit = geography_map.dig("values", value)
    if explicit.is_a?(Hash)
      result = explicit.transform_keys(&:to_s).slice(*GEOGRAPHY_FIELDS).reject { |_key, item| clean_scalar(item).empty? }
      return result unless result.empty?
    end

    if geography_map.fetch("rules", {}).fetch("dynastic_chao_suffix_is_period", false) && value.end_with?("朝")
      return { "period" => value }
    end

    # This exactly follows the migration's TIMES fallback: a non-date TIMES
    # value is period evidence unless the explicit geography map says more.
    { "period" => value }
  end

  def merge_scalar!(container, key, raw_value, source_key:, scope:, operations:, conflicts:, target_label: nil, legacy_line_value: nil)
    candidate = clean_scalar(raw_value)
    target = target_label || key
    if candidate.empty?
      operations << operation_row(source_key, scope, target, raw_value, container[key], container[key], "blank_ignored", "Blank legacy value")
      return
    end

    existing = container[key]
    if blank_value?(existing)
      container[key] = candidate
      operations << operation_row(source_key, scope, target, raw_value, existing, candidate, "add", "Added legacy value to JSON")
    elsif equivalent_scalar?(existing, candidate)
      operations << operation_row(source_key, scope, target, raw_value, existing, existing, "already_present", "JSON already contains the same value")
    elsif repairable_legacy_header_bleed?(existing, candidate, legacy_line_value)
      container[key] = candidate
      operations << operation_row(
        source_key, scope, target, raw_value, existing, candidate,
        "repair_legacy_header_bleed",
        "Replaced an exact old line-based header parsing artefact with the correctly parsed value"
      )
    else
      conflict = operation_row(source_key, scope, target, raw_value, existing, existing, "conflict", "Existing JSON value differs from legacy header")
      conflicts << conflict
      operations << conflict
    end
  end

  def repairable_legacy_header_bleed?(existing, candidate, legacy_line_value)
    existing_text = clean_scalar(existing)
    candidate_text = clean_scalar(candidate)
    line_text = clean_scalar(legacy_line_value)
    return false if existing_text.empty? || candidate_text.empty? || line_text.empty?
    return false unless equivalent_scalar?(existing_text, line_text)
    return false unless line_text.start_with?(candidate_text)

    suffix = line_text[candidate_text.length..].to_s
    expected_marker = EXPECTED_HEADER_KEYS.map { |key| Regexp.escape(key) }.join("|")
    suffix.match?(/\A[ \t]*#[ \t]*(?:#{expected_marker})[ \t]*:/)
  end

  def merge_list!(container, key, raw_value, pattern, source_key:, scope:, operations:, conflicts:, compare_names: false)
    candidates = split_list(raw_value, pattern)
    if candidates.empty?
      operations << operation_row(source_key, scope, key, raw_value, container[key], container[key], "blank_ignored", "Blank legacy value")
      return
    end

    existing = container[key]
    if blank_value?(existing)
      container[key] = candidates
      operations << operation_row(source_key, scope, key, raw_value, existing, candidates, "add", "Added legacy list to JSON")
      return
    end

    existing_values = compare_names ? names_from_list(existing) : scalar_list(existing)
    if equivalent_lists?(existing_values, candidates)
      operations << operation_row(source_key, scope, key, raw_value, existing, existing, "already_present", "JSON already contains the same list")
    else
      conflict = operation_row(source_key, scope, key, raw_value, existing, existing, "conflict", "Existing JSON list differs from legacy header")
      conflicts << conflict
      operations << conflict
    end
  end

  def operation_row(source_key, scope, target, header_value, existing, resulting, action, message)
    {
      "source_key" => source_key,
      "target_scope" => scope,
      "target" => target,
      "header_value" => serialise_value(header_value),
      "existing_value" => serialise_value(existing),
      "resulting_value" => serialise_value(resulting),
      "action" => action,
      "message" => message
    }
  end

  def mark_duplicate_ids!(rows, attribute, kind)
    rows.reject(&:blocker).group_by { |row| row.public_send(attribute) }.each do |value, grouped|
      next if value.nil? || grouped.length < 2
      paths = grouped.map { |row| row.source_path.to_s }.join("; ")
      grouped.each do |row|
        row.blocker = kind
        row.action = "blocked"
        row.message = "#{attribute} #{value} is shared by multiple flat works: #{paths}"
      end
    end
  end

  def document_records(value, found = [])
    case value
    when Hash
      if value.key?("document_id") && (value.key?("file") || value.key?("path"))
        found << value
      end
      value.each_value { |child| document_records(child, found) }
    when Array
      value.each { |child| document_records(child, found) }
    end
    found
  end

  def parse_leading_legacy_header(text)
    lines = text.lines
    index = 0
    index += 1 while index < lines.length && blank_line_after_optional_bom?(lines[index])
    return { status: "none", body: text } if index >= lines.length

    remainder = lines[index..].join.sub(/\A\uFEFF/, "")
    first_key = header_key(remainder)
    return { status: "none", body: text.sub(/\A\uFEFF/, "") } unless first_key

    marker = /#[ \t]*([A-Z_]+)[ \t]*:/
    matches = []
    remainder.to_enum(:scan, marker).each do
      match = Regexp.last_match
      matches << { key: match[1], begin: match.begin(0), end: match.end(0) }
      break if matches.length > EXPECTED_HEADER_KEYS.length
    end

    actual_keys = matches.first(EXPECTED_HEADER_KEYS.length).map { |row| row.fetch(:key) }
    unless actual_keys == EXPECTED_HEADER_KEYS
      mismatch_index = EXPECTED_HEADER_KEYS.each_index.find do |position|
        actual_keys[position] != EXPECTED_HEADER_KEYS[position]
      end || actual_keys.length
      expected = EXPECTED_HEADER_KEYS[mismatch_index]
      actual = actual_keys[mismatch_index]
      return {
        status: "partial_legacy_header",
        body: text,
        message: "Expected legacy header key #{expected}, found #{actual || 'end of header'}"
      }
    end

    categories = matches.fetch(EXPECTED_HEADER_KEYS.length - 1)
    categories_line_end = remainder.index("\n", categories.fetch(:end)) || remainder.length
    header_prefix = remainder[0...categories_line_end]
    if header_prefix.bytesize > 8_192 || header_prefix.count("\n") >= 20
      return {
        status: "partial_legacy_header",
        body: text,
        message: "Legacy header markers extend implausibly far into the document"
      }
    end

    markers_in_header = header_prefix.scan(marker).flatten
    if markers_in_header != EXPECTED_HEADER_KEYS
      extra = markers_in_header[EXPECTED_HEADER_KEYS.length]
      return {
        status: "partial_legacy_header",
        body: text,
        message: "Unexpected extra legacy header key #{extra || markers_in_header.inspect}"
      }
    end

    values = {}
    line_values = {}
    EXPECTED_HEADER_KEYS.each_with_index do |key, position|
      current = matches.fetch(position)
      value_end = if position + 1 < EXPECTED_HEADER_KEYS.length
                    matches.fetch(position + 1).fetch(:begin)
                  else
                    categories_line_end
                  end
      raw = remainder[current.fetch(:end)...value_end].to_s
      values[key] = clean_header_value(raw)

      physical_line_end = remainder.index("\n", current.fetch(:end)) || remainder.length
      raw_line_value = remainder[current.fetch(:end)...physical_line_end].to_s
      line_values[key] = clean_header_value(raw_line_value)
    end

    body_start = categories_line_end
    body_start += 1 if body_start < remainder.length && remainder.getbyte(body_start) == 10
    body = remainder[body_start..].to_s
    body = body.sub(/\A(?:[ \t]*\r?\n)+/, "")
    body = body.sub(/\A\uFEFF/, "")

    {
      status: "full_legacy_header",
      body: body,
      keys: EXPECTED_HEADER_KEYS,
      values: values,
      line_values: line_values
    }
  end

  def clean_header_value(value)
    value.to_s.gsub(/\r?\n[ \t]*/, " ").strip
  end

  def blank_line_after_optional_bom?(line)
    line.sub(/\A\uFEFF/, "").strip.empty?
  end

  def header_key(line)
    match = line.match(/\A[ \t]*#[ \t]*([A-Z_]+)[ \t]*:/)
    match && match[1]
  end

  def apply_one(corpus_root, row, backup_root)
    source_backup = backup_root.join(row.old_document_path)
    metadata_backup = backup_root.join(relative(corpus_root, row.metadata_path))
    copy_once(row.source_path, source_backup) if row.source_path.file?
    copy_once(row.metadata_path, metadata_backup)
    copy_once(row.target_path, backup_root.join(relative(corpus_root, row.target_path) + ".preexisting")) if row.target_path.file?

    raise "Apply attempted without prepared metadata for #{row.title}" unless row.updated_metadata

    FileUtils.mkdir_p(row.target_path.dirname)
    atomic_write(row.target_path, row.body)
    atomic_write(row.metadata_path, JSON.pretty_generate(row.updated_metadata) + "\n")

    written = row.target_path.binread.force_encoding(Encoding::UTF_8)
    raise "Target verification failed: #{row.target_path}" unless written.valid_encoding? && written == row.body
    reparsed = read_json(row.metadata_path)
    verify_one_metadata!(reparsed, row, corpus_root)

    with_retry("delete old flat TXT #{row.source_path}") { row.source_path.delete } if row.source_path.file? && row.source_path != row.target_path
  end

  def verify_all!(corpus_root, rows, workflow)
    failures = []
    rows.each do |row|
      failures << "Flat source remains: #{row.source_path}" if row.source_path.file? && row.source_path != row.target_path
      unless row.target_path.file?
        failures << "Target missing: #{row.target_path}"
        next
      end
      text = row.target_path.binread.force_encoding(Encoding::UTF_8)
      failures << "Invalid UTF-8 target: #{row.target_path}" unless text.valid_encoding?
      failures << "Legacy header remains: #{row.target_path}" if parse_leading_legacy_header(text)[:status] != "none"
      metadata = read_json(row.metadata_path)
      verify_one_metadata!(metadata, row, corpus_root)
      representation_conflicts = verify_header_representation(metadata, row.document_id, row.header_values, row.header_line_values, workflow)
      representation_conflicts.each { |message| failures << "#{row.title}: #{message}" }
    rescue StandardError => error
      failures << "#{row.title}: #{error.class}: #{error.message}"
    end
    return if failures.empty?

    raise "Post-apply verification failed:\n- #{failures.first(50).join("\n- ")}"
  end

  def verify_one_metadata!(metadata, row, corpus_root)
    raise "work_id changed: #{row.metadata_path}" unless integer_id(metadata["work_id"]) == row.work_id
    record = document_records(metadata).find { |item| integer_id(item["document_id"]) == row.document_id }
    raise "document_id missing after apply: #{row.document_id}" unless record
    raise "document path incorrect after apply: #{row.metadata_path}" unless record["path"].to_s == relative(corpus_root, row.target_path)
    raise "body_start_line is not 1: #{row.metadata_path}" unless integer_id(record["body_start_line"]) == 1
  end

  def verify_header_representation(metadata, document_id, header_values, header_line_values, workflow)
    _updated, _operations, conflicts = merge_header_into_metadata(
      metadata: metadata,
      document_id: document_id,
      header_values: header_values,
      header_line_values: header_line_values,
      workflow: workflow
    )
    conflicts.map { |conflict| "header value not represented in JSON: #{conflict['source_key']} -> #{conflict['target']}" }
  end

  def write_plan_reports(output_root, rows, options, started_at)
    plan_rows = rows.map do |row|
      additions = Array(row.merge_operations).count { |op| op["action"] == "add" }
      confirmed = Array(row.merge_operations).count { |op| op["action"] == "already_present" }
      blanks = Array(row.merge_operations).count { |op| op["action"] == "blank_ignored" }
      conflicts = Array(row.metadata_conflicts).length
      repairs = Array(row.merge_operations).count { |op| op["action"] == "repair_legacy_header_bleed" }
      {
        "title" => row.title,
        "source_path" => row.source_path.to_s,
        "target_path" => row.target_path.to_s,
        "metadata_path" => row.metadata_path.to_s,
        "work_id" => row.work_id,
        "document_id" => row.document_id,
        "old_document_path" => row.old_document_path,
        "new_document_path" => row.new_document_path,
        "header_status" => row.header_status,
        "header_work_title" => row.header_values&.fetch("WORK_TITLE", nil),
        "header_display_title" => row.header_values&.fetch("DISPLAY_TITLE", nil),
        "header_author" => row.header_values&.fetch("AUTHOR", nil),
        "header_times" => row.header_values&.fetch("TIMES", nil),
        "header_page_title" => row.header_values&.fetch("PAGE_TITLE", nil),
        "header_categories" => row.header_values&.fetch("CATEGORIES", nil),
        "metadata_values_to_add" => additions,
        "metadata_values_confirmed" => confirmed,
        "blank_header_values" => blanks,
        "metadata_conflicts" => conflicts,
        "metadata_repairs" => repairs,
        "target_status" => row.target_status,
        "action" => row.action,
        "blocker" => row.blocker ? "true" : "false",
        "blocker_kind" => row.blocker,
        "message" => row.message,
        "source_sha256" => row.source_sha256,
        "body_sha256" => row.body_sha256
      }
    end
    write_csv(output_root.join("plan.csv"), plan_rows)
    write_csv(output_root.join("blockers.csv"), plan_rows.select { |row| row["blocker"] == "true" })

    merge_rows = rows.flat_map do |row|
      Array(row.merge_operations).map do |operation|
        {
          "title" => row.title,
          "source_path" => row.source_path.to_s,
          "metadata_path" => row.metadata_path.to_s,
          "work_id" => row.work_id,
          "document_id" => row.document_id
        }.merge(operation)
      end
    end
    write_csv(output_root.join("metadata_merge.csv"), merge_rows)
    write_csv(output_root.join("metadata_conflicts.csv"), merge_rows.select { |row| row["action"] == "conflict" })

    action_counts = merge_rows.group_by { |row| row["action"] }.transform_values(&:length)
    by_source_key = EXPECTED_HEADER_KEYS.to_h do |key|
      selected = merge_rows.select { |row| row["source_key"] == key }
      [key, selected.group_by { |row| row["action"] }.transform_values(&:length)]
    end

    summary = {
      "version" => 3,
      "mode" => options.apply ? "apply_preflight" : "dry_run",
      "started_at" => started_at.iso8601,
      "created_at" => Time.now.utc.iso8601,
      "selected_files" => rows.length,
      "validated" => rows.count { |row| !row.blocker },
      "blockers" => rows.count(&:blocker),
      "full_legacy_headers" => rows.count { |row| row.header_status == "full_legacy_header" },
      "target_absent" => rows.count { |row| row.target_status == "absent" },
      "preexisting_compatible_targets" => rows.count { |row| row.target_status && row.target_status != "absent" },
      "unique_work_ids" => rows.map(&:work_id).compact.uniq.length,
      "unique_document_ids" => rows.map(&:document_id).compact.uniq.length,
      "metadata_merge_actions" => action_counts,
      "metadata_merge_by_header_key" => by_source_key,
      "partial" => !options.max_files.nil?,
      "max_files" => options.max_files
    }
    atomic_write(output_root.join("summary.json"), JSON.pretty_generate(summary) + "\n")
    atomic_write(output_root.join("summary.txt"), <<~TEXT)
      維基大典 JSON + layout migration plan
      ====================================
      Mode: #{options.apply ? 'APPLY PREFLIGHT' : 'DRY RUN'}
      Selected flat TXT files: #{summary['selected_files']}
      Validated: #{summary['validated']}
      Blockers: #{summary['blockers']}
      Complete six-key legacy headers: #{summary['full_legacy_headers']}
      Targets absent: #{summary['target_absent']}
      Compatible pre-existing targets: #{summary['preexisting_compatible_targets']}
      Unique numeric work IDs: #{summary['unique_work_ids']}
      Unique numeric document IDs: #{summary['unique_document_ids']}

      Header-to-JSON merge:
      Values to add: #{action_counts.fetch('add', 0)}
      Values already present: #{action_counts.fetch('already_present', 0)}
      Old parser artefacts repaired: #{action_counts.fetch('repair_legacy_header_bleed', 0)}
      Blank values ignored: #{action_counts.fetch('blank_ignored', 0)}
      Metadata conflicts: #{action_counts.fetch('conflict', 0)}

      Per legacy key:
      #{EXPECTED_HEADER_KEYS.map { |key|
        counts = by_source_key.fetch(key, {})
        "#{key}: add=#{counts.fetch('add', 0)}, present=#{counts.fetch('already_present', 0)}, repair=#{counts.fetch('repair_legacy_header_bleed', 0)}, blank=#{counts.fetch('blank_ignored', 0)}, conflict=#{counts.fetch('conflict', 0)}"
      }.join("\n")}

      Partial plan: #{summary['partial']}
    TEXT
  end

  def write_csv(path, rows)
    headers = rows.flat_map(&:keys).uniq
    headers = %w[message] if headers.empty?
    CSV.open(path, "wb", write_headers: true, headers: headers, encoding: "UTF-8") do |csv|
      rows.each { |row| csv << headers.map { |header| row[header] } }
    end
  end

  def split_list(value, pattern)
    value.to_s.split(pattern).map { |item| clean_scalar(item) }.reject(&:empty?).uniq
  end

  def names_from_list(value)
    Array(value).filter_map do |item|
      item.is_a?(Hash) ? clean_scalar(item["name"]) : clean_scalar(item)
    end.reject(&:empty?).uniq
  end

  def scalar_list(value)
    Array(value).map { |item| clean_scalar(item) }.reject(&:empty?).uniq
  end

  def equivalent_lists?(left, right)
    left.map { |item| normalise_text(item) }.sort == right.map { |item| normalise_text(item) }.sort
  end

  def equivalent_scalar?(left, right)
    normalise_text(left) == normalise_text(right)
  end

  def normalise_text(value)
    clean_scalar(value).unicode_normalize(:nfc)
  end

  def clean_scalar(value)
    value.to_s.strip
  end

  def blank_value?(value)
    value.nil? || value == false || (value.respond_to?(:empty?) && value.empty?) || value.to_s.strip.empty?
  end

  def serialise_value(value)
    case value
    when nil
      ""
    when String
      value
    else
      JSON.generate(value)
    end
  rescue JSON::GeneratorError
    value.to_s
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

  def read_json(path)
    raw = with_retry("read #{path}") { path.binread }
    text = raw.force_encoding(Encoding::UTF_8)
    raise "Invalid UTF-8 JSON: #{path}" unless text.valid_encoding?
    JSON.parse(text.sub(/\A\uFEFF/, ""))
  end

  def atomic_write(path, content)
    path = Pathname.new(path)
    FileUtils.mkdir_p(path.dirname)
    temp = path.dirname.join(".#{path.basename}.tmp-#{Process.pid}-#{rand(1_000_000)}")
    with_retry("write #{path}") do
      File.open(temp, "wb") do |file|
        file.write(content.encode(Encoding::UTF_8))
        file.flush
        file.fsync
      end
      File.rename(temp, path)
    end
  ensure
    FileUtils.rm_f(temp) if defined?(temp) && temp&.exist?
  end

  def copy_once(source, target)
    return if target.file?
    FileUtils.mkdir_p(target.dirname)
    with_retry("backup #{source}") { FileUtils.copy_file(source, target, true) }
  end

  def with_retry(label, attempts: 6)
    count = 0
    begin
      count += 1
      yield
    rescue *RETRYABLE_ERRORS => error
      raise if count >= attempts
      sleep_time = [0.25 * (2**(count - 1)), 4.0].min
      warn "#{label}: #{error.class}; retry #{count}/#{attempts - 1} in #{sleep_time}s"
      sleep sleep_time
      retry
    end
  end

  def integer_id(value)
    return value if value.is_a?(Integer) && value.positive?
    text = value.to_s
    return nil unless text.match?(/\A[1-9]\d*\z/)
    text.to_i
  end

  def relative(root, path)
    Pathname.new(path).relative_path_from(Pathname.new(root)).to_s.tr("\\", "/")
  end

  def deep_copy(value)
    Marshal.load(Marshal.dump(value))
  end

  def block(row, kind, message)
    row.blocker = kind
    row.action = "blocked"
    row.message = message
    row
  end

  def abort_with(message)
    warn message
    exit 2
  end
end

exit RepairWikiCleanLayout.run(ARGV)
