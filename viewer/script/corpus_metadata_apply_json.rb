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

# Applies a reviewed JSON metadata preflight.
#
# Default mode is another dry run. It only makes changes with --apply.
# The script moves txt files into contained-work folders before writing the
# corresponding metadata.json files, so metadata remains beside the work's text.
class CorpusMetadataApplyJson
  def initialize(options)
    @dry_run_output = Pathname(options.fetch(:dry_run_output)).expand_path
    @preflight_output = Pathname(options.fetch(:preflight_output)).expand_path
    @corpus_root = Pathname(options.fetch(:corpus_root)).expand_path
    @apply = options.fetch(:apply)
    @allow_overwrite = options.fetch(:allow_overwrite)
    @strip_txt_headers = options.fetch(:strip_txt_headers)
    @strip_header_audit = options[:strip_header_audit] ? Pathname(options[:strip_header_audit]).expand_path : nil
    @strip_report_rows = []
    @strip_audit_line_numbers = Hash.new { |hash, key| hash[key] = Set.new }
    @strip_path_aliases = Hash.new { |hash, key| hash[key] = Set.new }
    @progress_every = options.fetch(:progress_every).to_i
    @started_at = Time.now.utc
    @records_by_work_id = {}
    @moves = []
    @writes = []
    @identical_text_merges = []
    @metadata_write_resume_rows = []
    @work_id_remap = {}
    @document_index = Hash.new { |hash, key| hash[key] = [] }
  end

  def run
    progress "validating inputs"
    validate!
    progress "loading staged metadata"
    load_metadata_records!
    progress "loading preflight move/write plans"
    load_preflight!
    progress "normalising duplicate metadata destinations"
    normalize_duplicate_metadata_destinations!
    progress "merging identical-text duplicate metadata"
    merge_identical_text_metadata!
    progress @apply ? "applying identical-text deduplication" : "dry-run identical-text deduplication"
    apply_identical_text_dedupes!
    progress @apply ? "applying txt moves" : "dry-run txt moves"
    apply_moves!
    progress @apply ? "writing metadata.json files" : "dry-run metadata writes"
    apply_metadata_writes!
    write_metadata_resume_report! if @apply
    if @strip_txt_headers
      progress "loading txt header strip audit" if @strip_header_audit
      load_strip_header_audit! if @strip_header_audit
      progress @apply ? "stripping old txt headers" : "dry-run txt header stripping"
      strip_txt_headers!
      write_strip_report!
      abort_on_strip_failures! if @apply
    end
    progress "finished"
    warn "[metadata-apply] mode=#{@apply ? 'APPLY' : 'DRY RUN'} duplicate_merges=#{@identical_text_merges.length} moves=#{@moves.length} metadata_writes=#{@writes.length} header_strip_candidates=#{@strip_report_rows.count { |row| row[:status] == 'would_strip' || row[:status] == 'stripped' }}"
  end

  private

  def validate!
    raise ArgumentError, "Dry-run output does not exist: #{@dry_run_output}" unless @dry_run_output.directory?
    raise ArgumentError, "Preflight output does not exist: #{@preflight_output}" unless @preflight_output.directory?
    raise ArgumentError, "Corpus root does not exist: #{@corpus_root}" unless @corpus_root.directory?
    %w[staged_metadata.jsonl].each do |name|
      raise ArgumentError, "Missing #{name} in #{@dry_run_output}" unless @dry_run_output.join(name).file?
    end
    %w[would_write_metadata_json.csv would_move_txt_files.csv would_skip.csv would_overwrite.csv would_merge_identical_txt_files.csv].each do |name|
      raise ArgumentError, "Missing #{name} in #{@preflight_output}; rerun preflight" unless @preflight_output.join(name).file?
    end

    skip_count = csv_row_count(@preflight_output.join("would_skip.csv"))
    if skip_count.positive?
      warn_skip_summary(@preflight_output.join("would_skip.csv"))
      raise ArgumentError, "Preflight has #{skip_count} problem rows in would_skip.csv; fix those before applying"
    end

    overwrite_count = csv_row_count(@preflight_output.join("would_overwrite.csv"))
    if overwrite_count.positive? && !@allow_overwrite
      raise ArgumentError, "Preflight has #{overwrite_count} metadata.json overwrite rows. Pass --allow-overwrite only after reviewing would_overwrite.csv."
    end
  end

  def warn_skip_summary(path)
    counts = Hash.new(0)
    CSV.foreach(path, headers: true, encoding: "bom|utf-8") do |row|
      counts[row["reason"].to_s] += 1
    end
    warn "[metadata-apply] preflight problem summary:"
    counts.sort_by { |_, count| -count }.each do |reason, count|
      warn "[metadata-apply]   #{count} #{reason}"
    end
  end

  def progress(message)
    warn "[metadata-apply] #{Time.now.utc.iso8601} #{message}"
  end

  def maybe_progress(count, label)
    return unless @progress_every.positive?
    return unless (count % @progress_every).zero?

    progress "#{label}: #{count}"
  end

  def load_metadata_records!
    count = 0
    File.foreach(@dry_run_output.join("staged_metadata.jsonl"), encoding: "UTF-8") do |line|
      next if line.strip.empty?
      payload = JSON.parse(line)
      @records_by_work_id[payload.fetch("work_id").to_s] = payload
      index_documents!(payload)
      count += 1
      maybe_progress(count, "metadata records loaded")
    end
  end

  def load_preflight!
    CSV.foreach(@preflight_output.join("would_move_txt_files.csv"), headers: true, encoding: "bom|utf-8") do |row|
      @moves << row.to_h
    end
    CSV.foreach(@preflight_output.join("would_write_metadata_json.csv"), headers: true, encoding: "bom|utf-8") do |row|
      @writes << row.to_h
    end
    CSV.foreach(@preflight_output.join("would_merge_identical_txt_files.csv"), headers: true, encoding: "bom|utf-8") do |row|
      @identical_text_merges << row.to_h
    end
  end

  def index_documents!(payload)
    each_document_hash(payload) do |document|
      path = document["path"].to_s
      @document_index[path] << document unless path.empty?
    end
  end

  def each_document_hash(payload, &block)
    Array(payload["documents"]).each(&block)
    Array(payload["editions"]).each do |edition|
      Array(edition["documents"]).each(&block)
    end
  end

  def normalize_duplicate_metadata_destinations!
    grouped = @writes.group_by { |row| row.fetch("relative_metadata_path") }
    duplicate_groups = grouped.select { |_path, rows| rows.length > 1 }
    return if duplicate_groups.empty?

    progress "duplicate metadata destinations: #{duplicate_groups.length}"
    normalised_writes = []

    grouped.each_value do |rows|
      if rows.length == 1
        normalised_writes << rows.first
        next
      end

      primary = choose_primary_metadata_write(rows)
      primary_id = primary.fetch("work_id").to_s
      rows.each do |row|
        work_id = row.fetch("work_id").to_s
        next if work_id == primary_id

        @work_id_remap[work_id] = primary_id
        merge_duplicate_work_payload!(primary_id, work_id)
      end
      normalised_writes << primary
    end

    @writes = normalised_writes
    remap_work_references!
    progress "metadata writes after duplicate-destination normalisation: #{@writes.length}"
  end

  def choose_primary_metadata_write(rows)
    rows.find { |row| row["kind"].to_s == "folder_work" } || rows.first
  end

  def canonical_work_id(work_id)
    current = work_id.to_s
    seen = Set.new
    while @work_id_remap.key?(current) && !seen.include?(current)
      seen << current
      current = @work_id_remap[current]
    end
    current
  end

  def merge_duplicate_work_payload!(primary_id, duplicate_id)
    primary = @records_by_work_id.fetch(primary_id) { raise "No staged metadata record for primary work_id=#{primary_id}" }
    duplicate = @records_by_work_id.fetch(duplicate_id) { raise "No staged metadata record for duplicate work_id=#{duplicate_id}" }
    merged = merge_work_payloads(primary, duplicate)
    primary.clear
    primary.merge!(deep_compact(merged))
  end

  def merge_work_payloads(primary, duplicate)
    merged = merge_hashes(primary, duplicate)
    merged["work_id"] = primary.fetch("work_id")
    merged["title"] = primary["title"] unless blank?(primary["title"])
    merged["is_compilation"] = primary["is_compilation"] unless primary["is_compilation"].nil?
    merged
  end

  def remap_work_references!
    return if @work_id_remap.empty?

    @records_by_work_id.each_value do |payload|
      remap_work_references_in_object!(payload)
      remove_self_worklist_references!(payload)
    end
  end

  def remove_self_worklist_references!(payload)
    self_id = payload["work_id"].to_s
    return if self_id.empty?

    if payload["worklist"].is_a?(Array)
      payload["worklist"] = payload["worklist"].reject { |item| item.is_a?(Hash) && item["work_id"].to_s == self_id }
    end
    if payload["contained_works"].is_a?(Array)
      payload["contained_works"] = payload["contained_works"].reject { |item| item.is_a?(Hash) && item["work_id"].to_s == self_id }
    end
  end

  def remap_work_references_in_object!(object)
    case object
    when Hash
      object.each do |key, value|
        if work_id_reference_key?(key) && @work_id_remap.key?(value.to_s)
          object[key] = canonical_work_id(value.to_s).to_i.to_s == canonical_work_id(value.to_s) ? canonical_work_id(value.to_s).to_i : canonical_work_id(value.to_s)
        else
          remap_work_references_in_object!(value)
        end
      end
    when Array
      object.each { |item| remap_work_references_in_object!(item) }
    end
  end

  def work_id_reference_key?(key)
    text = key.to_s
    text == "work_id" || text.end_with?("_work_id") || text == "source_work_id"
  end

  def merge_identical_text_metadata!
    @identical_text_merges.each_with_index do |row, index|
      work_id = row.fetch("work_id").to_s
      payload = @records_by_work_id.fetch(work_id) { raise "No staged metadata record for work_id=#{work_id}" }
      source_path = row.fetch("source_path")
      target_path = row.fetch("target_path")
      keep_path = row.fetch("keep_path")

      primary_doc = find_document(payload, target_path) || find_document(payload, source_path)
      primary_doc ||= first_document_for_path(target_path) || first_document_for_path(source_path)
      next unless primary_doc

      docs_to_merge = ([primary_doc] + @document_index[source_path] + @document_index[target_path]).uniq
      merged = docs_to_merge.reduce({}) { |memo, doc| merge_document_hashes(memo, doc) }
      merged["path"] = target_path
      merged["file"] = File.basename(target_path)
      merged["duplicate_text_sources"] = merge_duplicate_source_notes(
        Array(merged["duplicate_text_sources"]),
        row.merge("kept_physical_path" => keep_path)
      )

      primary_doc.clear
      primary_doc.merge!(deep_compact(merged))
      remove_duplicate_document_entries!(payload, primary_doc, source_path, target_path)
      maybe_progress(index + 1, "duplicate metadata merges processed")
    end
  end

  def find_document(payload, path)
    found = nil
    each_document_hash(payload) do |document|
      if document["path"].to_s == path.to_s
        found = document
        break
      end
    end
    found
  end

  def first_document_for_path(path)
    @document_index[path].first
  end

  def remove_duplicate_document_entries!(payload, primary_doc, source_path, target_path)
    if payload["documents"].is_a?(Array)
      payload["documents"] = collapse_document_array(payload["documents"], primary_doc, source_path, target_path)
    end
    Array(payload["editions"]).each do |edition|
      next unless edition["documents"].is_a?(Array)
      edition["documents"] = collapse_document_array(edition["documents"], primary_doc, source_path, target_path)
    end
  end

  def collapse_document_array(documents, primary_doc, source_path, target_path)
    seen_primary = false
    documents.filter_map do |document|
      path = document["path"].to_s
      if document.equal?(primary_doc)
        if seen_primary
          nil
        else
          seen_primary = true
          document
        end
      elsif path == source_path || path == target_path
        nil
      else
        document
      end
    end
  end

  def merge_document_hashes(left, right)
    merged = left.dup
    right.each do |key, value|
      next if value.nil?
      if value.is_a?(Array)
        merged[key] = merge_arrays(Array(merged[key]), value)
      elsif value.is_a?(Hash)
        merged[key] = merge_hashes(merged[key].is_a?(Hash) ? merged[key] : {}, value)
      elsif blank?(merged[key])
        merged[key] = value
      elsif merged[key] == value
        merged[key] = value
      end
    end
    merged
  end

  def merge_hashes(left, right)
    merged = left.dup
    right.each do |key, value|
      next if value.nil?
      if value.is_a?(Array)
        merged[key] = merge_arrays(Array(merged[key]), value)
      elsif value.is_a?(Hash)
        merged[key] = merge_hashes(merged[key].is_a?(Hash) ? merged[key] : {}, value)
      elsif blank?(merged[key])
        merged[key] = value
      elsif merged[key] == value
        merged[key] = value
      end
    end
    merged
  end

  def merge_arrays(left, right)
    (left + right).reject { |item| blank?(item) }.uniq { |item| JSON.generate(item) }
  end

  def merge_duplicate_source_notes(existing, row)
    note = {
      "source_path" => row.fetch("source_path"),
      "target_path" => row.fetch("target_path"),
      "kept_physical_path" => row.fetch("kept_physical_path"),
      "removed_physical_path" => row.fetch("remove_path"),
      "text_sha256" => row["text_sha256"],
      "source_mtime" => row["source_mtime"],
      "target_mtime" => row["target_mtime"]
    }
    merge_arrays(existing, [note])
  end

  def apply_identical_text_dedupes!
    @identical_text_merges.each_with_index do |row, index|
      source = @corpus_root.join(row.fetch("source_path"))
      target = @corpus_root.join(row.fetch("target_path"))
      keep_path = row.fetch("keep_path")
      remove_path = row.fetch("remove_path")
      keep = @corpus_root.join(keep_path)
      remove = @corpus_root.join(remove_path)

      if @apply
        if keep.file? && !remove.file?
          # Resume mode: duplicate was already removed by an interrupted run.
        else
          raise "Missing duplicate source during apply: #{source}" unless source.file?
          raise "Missing duplicate target during apply: #{target}" unless target.file?
          unless same_text_body?(source, target)
            raise "Duplicate text changed since preflight: #{source} vs #{target}"
          end

          if keep.expand_path == source.expand_path
            FileUtils.mkdir_p(target.dirname)
            FileUtils.rm_f(target)
            FileUtils.mv(source, target)
          else
            FileUtils.rm_f(remove)
          end
        end
      end
      maybe_progress(index + 1, "identical-text dedupes processed")
    end
  end

  def apply_moves!
    @moves.each_with_index do |row, index|
      source = @corpus_root.join(row.fetch("source_path"))
      target = @corpus_root.join(row.fetch("target_path"))
      if @apply
        if source.file? && target.exist? && source.expand_path != target.expand_path
          raise "Target already exists during apply: #{target}"
        elsif source.file?
          FileUtils.mkdir_p(target.dirname)
          FileUtils.mv(source, target) unless source.expand_path == target.expand_path
        elsif target.file?
          # Resume mode: a previous interrupted run already moved this file.
        else
          raise "Missing source txt and target txt during apply resume: source=#{source} target=#{target}"
        end
      end
      maybe_progress(index + 1, "txt moves processed")
    end
  end

  def apply_metadata_writes!
    @writes.each_with_index do |row, index|
      work_id = canonical_work_id(row.fetch("work_id").to_s)
      payload = @records_by_work_id.fetch(work_id) { raise "No staged metadata record for work_id=#{work_id}" }
      destination = @corpus_root.join(row.fetch("relative_metadata_path"))
      if @apply
        FileUtils.mkdir_p(destination.dirname)
        write_metadata_json_resumable!(destination, payload, row)
      end
      maybe_progress(index + 1, "metadata writes processed")
    end
  end

  def write_metadata_json_resumable!(destination, payload, row)
    if destination.exist?
      if same_json_payload?(destination, payload)
        @metadata_write_resume_rows << resume_row(destination, row, "already_written_same_payload")
        return
      end

      existing = read_json_file(destination)
      if existing.is_a?(Hash) && existing["work_id"].to_s == payload["work_id"].to_s
        @metadata_write_resume_rows << resume_row(destination, row, "refresh_existing_same_work_id")
        atomic_write_json(destination, payload)
        return
      end

      unless @allow_overwrite
        raise "Refusing to overwrite existing metadata.json with different work_id: #{destination} existing_work_id=#{existing.is_a?(Hash) ? existing['work_id'] : nil} new_work_id=#{payload['work_id']}"
      end
    end

    atomic_write_json(destination, payload)
  end

  def same_json_payload?(destination, payload)
    existing = read_json_file(destination)
    existing == JSON.parse(JSON.generate(payload))
  rescue JSON::ParserError, SystemCallError
    false
  end

  def read_json_file(path)
    JSON.parse(path.read(encoding: "UTF-8"))
  rescue JSON::ParserError
    nil
  end

  def resume_row(destination, row, action)
    {
      action: action,
      work_id: canonical_work_id(row.fetch("work_id").to_s),
      title: row["title"],
      relative_metadata_path: destination.relative_path_from(@corpus_root).to_s
    }
  end

  def atomic_write_json(destination, payload)
    atomic_write_with_retries(destination, "tmp") do |temp|
      temp.write(JSON.pretty_generate(payload) + "\n")
    end
  end


  def strip_txt_headers!
    build_strip_path_aliases!
    paths = metadata_document_paths
    progress "txt header strip paths: #{paths.length}"
    paths.each_with_index do |relative_path, index|
      path = @corpus_root.join(relative_path)
      row = strip_txt_header_plan(path, relative_path)
      if @apply && row[:status] == "would_strip"
        begin
          atomic_write_bytes(path, row.fetch(:new_content))
          row[:status] = "stripped"
          row[:message] = ""
        rescue SystemCallError => error
          row[:status] = "write_failed"
          row[:message] = "#{error.class}: #{error.message}"
          warn "[metadata-apply] txt header strip failed for #{relative_path}: #{row[:message]}"
        ensure
          row.delete(:new_content)
        end
      else
        row.delete(:new_content)
      end
      @strip_report_rows << row
      maybe_progress(index + 1, "txt headers checked")
    end
  end

  def build_strip_path_aliases!
    metadata_document_paths.each { |path| @strip_path_aliases[path] << path }
    @moves.each do |row|
      target = row.fetch("target_path").to_s
      source = row.fetch("source_path").to_s
      @strip_path_aliases[target] << target
      @strip_path_aliases[target] << source unless source.empty?
    end
    @identical_text_merges.each do |row|
      [row["target_path"], row["keep_path"]].compact.each do |current|
        next if current.to_s.empty?
        @strip_path_aliases[current] << current
        @strip_path_aliases[current] << row["source_path"].to_s unless row["source_path"].to_s.empty?
        @strip_path_aliases[current] << row["target_path"].to_s unless row["target_path"].to_s.empty?
        @strip_path_aliases[current] << row["remove_path"].to_s unless row["remove_path"].to_s.empty?
      end
    end
  end

  def load_strip_header_audit!
    raise ArgumentError, "Header audit directory does not exist: #{@strip_header_audit}" unless @strip_header_audit.directory?

    metadata_rows = @strip_header_audit.join("metadata_rows.csv")
    malformed_rows = @strip_header_audit.join("malformed_headers.csv")
    raise ArgumentError, "Missing metadata_rows.csv in #{@strip_header_audit}" unless metadata_rows.file?

    build_strip_path_aliases! if @strip_path_aliases.empty?
    wanted_paths = @strip_path_aliases.values.reduce(Set.new) { |memo, aliases| memo.merge(aliases) }
    progress "txt header audit wanted paths: #{wanted_paths.length}"

    rows_read = 0
    CSV.foreach(metadata_rows, headers: true, encoding: "bom|utf-8") do |row|
      path = row["path"].to_s
      next unless wanted_paths.include?(path)

      line_number = row["line_number"].to_i
      @strip_audit_line_numbers[path] << line_number if line_number.positive?
      rows_read += 1
      maybe_progress(rows_read, "txt header audit rows matched")
    end

    if malformed_rows.file?
      CSV.foreach(malformed_rows, headers: true, encoding: "bom|utf-8") do |row|
        path = row["path"].to_s
        next unless wanted_paths.include?(path)

        line_number = row["line_number"].to_i
        @strip_audit_line_numbers[path] << line_number if line_number.positive?
      end
    end

    progress "txt header audit matched paths: #{@strip_audit_line_numbers.length}"
  end

  def metadata_document_paths
    paths = Set.new
    @writes.each do |row|
      payload = @records_by_work_id[row.fetch("work_id").to_s]
      next unless payload
      each_document_hash(payload) do |document|
        path = document["path"].to_s
        paths << path unless path.empty?
      end
    end
    paths.to_a.sort
  end

  def strip_txt_header_plan(path, relative_path)
    unless path.file?
      return {
        status: "missing",
        path: relative_path,
        stripped_lines: 0,
        stripped_bytes: 0,
        strip_mode: strip_mode_label(relative_path),
        message: "txt file missing"
      }
    end

    content = path.binread
    stripped = strip_audited_header_bytes(content, relative_path)
    stripped ||= strip_leading_hash_header_block(content)
    unless stripped
      return {
        status: "no_header",
        path: relative_path,
        stripped_lines: 0,
        stripped_bytes: 0,
        strip_mode: strip_mode_label(relative_path),
        message: "no leading old # header block detected"
      }
    end

    new_content, stripped_lines, stripped_bytes, mode = stripped
    return {
      status: "no_header",
      path: relative_path,
      stripped_lines: 0,
      stripped_bytes: 0,
      strip_mode: mode,
      message: "header strip would not change content"
    } if new_content == content

    {
      status: "would_strip",
      path: relative_path,
      stripped_lines: stripped_lines,
      stripped_bytes: stripped_bytes,
      strip_mode: mode,
      message: mode == "audit" ? "leading header block matched previous metadata audit" : "leading # header block fallback",
      new_content: new_content
    }
  rescue SystemCallError => error
    {
      status: "error",
      path: relative_path,
      stripped_lines: 0,
      stripped_bytes: 0,
      strip_mode: strip_mode_label(relative_path),
      message: "#{error.class}: #{error.message}"
    }
  end

  def strip_audited_header_bytes(content, relative_path)
    audit_lines = audited_line_numbers_for(relative_path)
    return nil if audit_lines.empty?

    strip_header_bytes(content, "audit") do |line, line_number, stripped_any|
      audit_lines.include?(line_number) || (stripped_any && line.strip.empty?)
    end
  end

  def strip_leading_hash_header_block(content)
    strip_header_bytes(content, "fallback_leading_hash_block") do |line, _line_number, stripped_any|
      line.start_with?("#") || (stripped_any && line.strip.empty?)
    end
  end

  def strip_header_bytes(content, mode)
    bom = "\xEF\xBB\xBF".b
    has_bom = content.start_with?(bom)
    prefix = has_bom ? bom : "".b
    body = has_bom ? content.byteslice(3..-1).to_s : content
    lines = body.lines
    return nil if lines.empty?

    index = 0
    stripped_lines = 0
    stripped_bytes = 0
    stripped_any = false
    while index < lines.length && yield(lines[index], index + 1, stripped_any)
      stripped_bytes += lines[index].bytesize
      stripped_lines += 1
      stripped_any = true
      index += 1
    end
    return nil if stripped_lines.zero?

    [prefix + (lines[index..]&.join || "".b), stripped_lines, stripped_bytes, mode]
  end

  def audited_line_numbers_for(relative_path)
    aliases = @strip_path_aliases[relative_path]
    aliases.each_with_object(Set.new) do |alias_path, memo|
      memo.merge(@strip_audit_line_numbers[alias_path])
    end
  end

  def strip_mode_label(relative_path)
    @strip_header_audit && !audited_line_numbers_for(relative_path).empty? ? "audit" : "fallback_leading_hash_block"
  end

  def atomic_write_bytes(destination, content)
    atomic_write_with_retries(destination, "strip-tmp") do |temp|
      File.binwrite(temp, content)
    end
  end

  def atomic_write_with_retries(destination, label)
    attempts = 0
    temp = nil
    safe_label = label.to_s.gsub(/[^A-Za-z0-9_-]/, "-")

    begin
      attempts += 1
      # Keep the temporary filename deliberately short.  Some corpus files have
      # very long basenames, and Windows/WSL can open the real file but reject
      # an atomic-write temp path such as `.VERY_LONG_FILENAME.txt.strip-tmp...`.
      # The temp still lives in the same directory, so the final rename remains
      # same-directory and effectively atomic.
      temp = destination.dirname.join(".fhwc-#{safe_label}-#{$$}-#{attempts}.tmp")
      FileUtils.rm_f(temp)
      yield temp
      File.rename(temp, destination)
    rescue Errno::EACCES, Errno::EPERM, Errno::EBUSY => error
      FileUtils.rm_f(temp) if temp && temp.exist?
      if attempts < 12
        sleep_time = [0.25 * attempts, 3.0].min
        warn "[metadata-apply] write retry #{attempts}/12 for #{destination}: #{error.class}: #{error.message}; sleeping #{sleep_time.round(2)}s"
        sleep sleep_time
        retry
      end
      raise
    ensure
      FileUtils.rm_f(temp) if temp && temp.exist?
    end
  end

  def abort_on_strip_failures!
    failures = @strip_report_rows.count { |row| row[:status] == "write_failed" }
    return if failures.zero?

    raise RuntimeError, "TXT header stripping had #{failures} write failures. See #{@preflight_output.join('stripped_txt_headers.csv')} and rerun after closing locked files / pausing OneDrive."
  end

  def write_metadata_resume_report!
    return if @metadata_write_resume_rows.empty?

    path = @preflight_output.join("resumed_metadata_writes.csv")
    headers = %w[action work_id title relative_metadata_path]
    CSV.open(path, "w", write_headers: true, headers: headers) do |csv|
      @metadata_write_resume_rows.each { |row| csv << headers.map { |key| row[key.to_sym] } }
    end
    progress "wrote resumed_metadata_writes.csv"
  end

  def write_strip_report!
    report_name = @apply ? "stripped_txt_headers.csv" : "would_strip_txt_headers.csv"
    path = @preflight_output.join(report_name)
    CSV.open(path, "w", write_headers: true, headers: %w[status path stripped_lines stripped_bytes strip_mode message]) do |csv|
      @strip_report_rows.each do |row|
        csv << [row[:status], row[:path], row[:stripped_lines], row[:stripped_bytes], row[:strip_mode], row[:message]]
      end
    end

    counts = @strip_report_rows.each_with_object(Hash.new(0)) { |row, memo| memo[row[:status]] += 1 }
    counts.sort_by { |_, count| -count }.each do |status, count|
      warn "[metadata-apply]   txt_header_strip #{status}=#{count}"
    end
    mode_counts = @strip_report_rows.each_with_object(Hash.new(0)) { |row, memo| memo[row[:strip_mode]] += 1 }
    mode_counts.sort_by { |_, count| -count }.each do |mode, count|
      warn "[metadata-apply]   txt_header_strip_mode #{mode}=#{count}"
    end
    progress "wrote #{report_name}"
  end


  def blank?(value)
    value.nil? || (value.respond_to?(:empty?) && value.empty?)
  end

  def deep_compact(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, item), output|
        compacted = deep_compact(item)
        output[key] = compacted unless blank?(compacted)
      end
    when Array
      value.filter_map { |item| deep_compact(item) }.reject { |item| blank?(item) }
    else
      value
    end
  end

  def same_text_body?(left, right)
    return false unless left.file? && right.file?

    text_body_bytes(left) == text_body_bytes(right)
  rescue SystemCallError
    false
  end

  def text_body_bytes(path)
    content = path.binread
    lines = content.lines
    index = 0
    index += 1 while index < lines.length && lines[index].start_with?("#")
    index += 1 while index < lines.length && lines[index].strip.empty?
    lines[index..]&.join || ""
  end

  def csv_row_count(path)
    count = 0
    CSV.foreach(path, headers: true, encoding: "bom|utf-8") { |_row| count += 1 }
    count
  end
end

options = {
  apply: false,
  allow_overwrite: false,
  strip_txt_headers: false,
  strip_header_audit: nil,
  progress_every: 25_000
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby script/corpus_metadata_apply_json.rb --dry-run-output DIR --preflight-output DIR --corpus-root DIR [--apply]"
  opts.on("--dry-run-output DIR", "Directory produced by corpus_metadata_json_dry_run.rb") { |value| options[:dry_run_output] = value }
  opts.on("--preflight-output DIR", "Directory produced by corpus_metadata_apply_preflight.rb") { |value| options[:preflight_output] = value }
  opts.on("--corpus-root DIR", "Corpus root") { |value| options[:corpus_root] = value }
  opts.on("--apply", "Actually move txt files and write metadata.json files") { options[:apply] = true }
  opts.on("--allow-overwrite", "Allow overwriting existing metadata.json files after reviewing would_overwrite.csv") { options[:allow_overwrite] = true }
  opts.on("--strip-txt-headers", "After metadata.json writes, strip old leading # metadata headers from covered txt files") { options[:strip_txt_headers] = true }
  opts.on("--strip-header-audit DIR", "Previous corpus_metadata_audit output. Uses metadata_rows.csv/malformed_headers.csv to strip exactly the audited old header block where possible") { |value| options[:strip_header_audit] = value }
  opts.on("--progress-every N", Integer, "Print progress every N rows. Default: 25000; 0 disables") { |value| options[:progress_every] = value }
end

parser.parse!(ARGV)
missing = %i[dry_run_output preflight_output corpus_root].select { |key| options[key].to_s.empty? }
if missing.any?
  warn parser
  abort "Missing required option(s): #{missing.join(', ')}"
end

CorpusMetadataApplyJson.new(options).run
