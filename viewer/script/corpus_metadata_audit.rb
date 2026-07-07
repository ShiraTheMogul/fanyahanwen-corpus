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

# Corpus metadata audit for the Fanya Hanwen Corpus.
#
# This is read-only. It scans leading # KEY: value headers in .txt files and
# writes CSV/JSON reports that are meant to guide the later JSON metadata
# migration. It does not edit corpus files.
class CorpusMetadataAudit
  HEADER_PATTERN = /\A#\s*([^:：]+?)\s*[:：]\s*(.*?)\s*\z/
  COMMENT_PATTERN = /\A#/
  BOM = "\uFEFF"

  SEPARATORS = {
    "," => "latin comma",
    "，" => "chinese comma",
    ";" => "latin semicolon",
    "；" => "chinese semicolon",
    "、" => "ideographic comma",
    "|" => "pipe",
    "/" => "slash",
    "／" => "fullwidth slash",
    "&" => "ampersand",
    " and " => "english and",
    " AND " => "english AND"
  }.freeze

  MAX_SAMPLE_VALUES = 12
  MAX_SAMPLE_PATHS = 12
  MAX_VALUE_SAMPLE_PATHS = 6

  FieldStats = Struct.new(
    :raw_key,
    :canonical_key,
    :files,
    :occurrences,
    :non_blank,
    :blank,
    :unique_values,
    :sample_values,
    :sample_paths,
    keyword_init: true
  )

  def initialize(corpus_root:, output_root:, include_rows:, max_files:, scan_all_comments:, strict_enumeration:, file_list:)
    @corpus_root = Pathname(corpus_root).expand_path
    @output_root = Pathname(output_root).expand_path
    @include_rows = include_rows
    @max_files = max_files
    @scan_all_comments = scan_all_comments
    @strict_enumeration = strict_enumeration
    @file_list = file_list ? Pathname(file_list).expand_path : nil

    @field_stats = {}
    @canonical_groups = Hash.new { |hash, key| hash[key] = Hash.new(0) }
    @value_counts = Hash.new { |hash, key| hash[key] = Hash.new(0) }
    @value_paths = Hash.new { |hash, key| hash[key] = Hash.new { |h, value| h[value] = [] } }
    @separator_counts = Hash.new { |hash, key| hash[key] = Hash.new(0) }
    @separator_samples = Hash.new { |hash, key| hash[key] = {} }
    @files = []
    @duplicates = []
    @malformed = []
    @read_errors = []
    @rows = []
    @folder_stats = Hash.new { |hash, key| hash[key] = { files: 0, metadata_files: 0, keys: Hash.new(0) } }
    @enumeration_errors = []
    @run_error = nil
  end

  def run
    validate!
    prepare_output!
    started = Time.now.utc
    txt_paths = []

    begin
      txt_paths = enumerate_txt_files
      write_enumeration_checkpoint(txt_paths)
      if @enumeration_errors.any?
        warn "[metadata-audit] enumeration had #{@enumeration_errors.length} unreadable paths; continuing with #{txt_paths.length} discovered text files"
      end

      txt_paths.each_with_index do |path, index|
        scan_file(path)
        if ((index + 1) % 10_000).zero?
          warn "[metadata-audit] scanned #{index + 1}/#{txt_paths.length} files"
          write_progress_json(started: started, total_files_seen: txt_paths.length, scanned_so_far: index + 1)
        end
      end
    rescue Interrupt
      @run_error = "Interrupt: audit interrupted by user"
      warn "[metadata-audit] interrupted; writing partial reports"
      raise
    rescue StandardError => error
      @run_error = "#{error.class}: #{error.message}"
      warn "[metadata-audit] unexpected error: #{@run_error}; writing partial reports"
      raise
    ensure
      write_reports(started: started, finished: Time.now.utc, total_files_seen: txt_paths.length) if @output_root.directory?
      warn "[metadata-audit] wrote reports to #{@output_root}" if @output_root.directory?
    end

    if @strict_enumeration && @enumeration_errors.any?
      warn "[metadata-audit] strict enumeration requested: reports were written, but #{@enumeration_errors.length} paths were unreadable"
      exit 2
    end
  end

  private

  def validate!
    raise ArgumentError, "Corpus root does not exist: #{@corpus_root}" unless @corpus_root.directory?
  end

  def prepare_output!
    FileUtils.mkdir_p(@output_root)
  end

  def write_enumeration_checkpoint(txt_paths)
    write_csv("txt_files.csv", txt_paths.map do |path|
      { path: path.relative_path_from(@corpus_root).to_s.tr("\\", "/") }
    end)
    write_csv("enumeration_errors.csv", @enumeration_errors)
    write_progress_json(started: Time.now.utc, total_files_seen: txt_paths.length, scanned_so_far: 0)
  end

  def write_progress_json(started:, total_files_seen:, scanned_so_far:)
    progress = {
      version: 1,
      corpus_root: @corpus_root.to_s,
      output_root: @output_root.to_s,
      text_files_discovered: total_files_seen,
      text_files_scanned_so_far: scanned_so_far,
      enumeration_errors: @enumeration_errors.length,
      read_errors: @read_errors.length,
      updated_at: Time.now.utc.iso8601,
      started_at: started.iso8601
    }
    @output_root.join("progress.json").write(JSON.pretty_generate(progress))
  end

  ENUMERATION_ERRORS = [
    Errno::EIO,
    Errno::EACCES,
    Errno::ENOENT,
    Errno::ENOTDIR,
    Errno::ENAMETOOLONG,
    Errno::ELOOP,
    SystemCallError
  ].freeze

  def enumerate_txt_files
    paths = @file_list ? enumerate_from_file_list : enumerate_by_directory_walk
    paths = paths.sort_by { |path| path.relative_path_from(@corpus_root).to_s }
    @max_files ? paths.first(@max_files) : paths
  end

  def enumerate_from_file_list
    raise ArgumentError, "File list does not exist: #{@file_list}" unless @file_list&.file?

    paths = []
    @file_list.each_line.with_index(1) do |line, line_number|
      raw = line.chomp
      next if raw.empty?

      path = Pathname(raw)
      path = @corpus_root.join(path) unless path.absolute?
      path = path.expand_path
      unless path.to_s.end_with?(".txt")
        @enumeration_errors << enumeration_error_row(path, "file_list", "not_a_txt_file", "line #{line_number}: #{raw}")
        next
      end
      unless path.file?
        @enumeration_errors << enumeration_error_row(path, "file_list", "missing_or_not_file", "line #{line_number}: #{raw}")
        next
      end

      paths << path
    rescue *ENUMERATION_ERRORS => error
      @enumeration_errors << enumeration_error_row(path || raw, "file_list", error.class.name, error.message)
    end
    paths
  end

  def enumerate_by_directory_walk
    paths = []
    walk_directory(@corpus_root, paths)
    paths
  end

  def walk_directory(directory, paths)
    entries = children_with_retries(directory)
    return unless entries

    entries.sort.each do |entry|
      child = directory.join(entry)
      begin
        if child.symlink?
          next
        elsif child.directory?
          walk_directory(child, paths)
        elsif child.file? && child.extname == ".txt"
          paths << child
          warn "[metadata-audit] discovered #{paths.length} text files" if (paths.length % 50_000).zero?
        end
      rescue *ENUMERATION_ERRORS => error
        @enumeration_errors << enumeration_error_row(child, "stat", error.class.name, error.message)
      end
    end
  end

  def children_with_retries(directory)
    attempts = 0

    begin
      directory.children.map { |child| child.basename.to_s }
    rescue *ENUMERATION_ERRORS => error
      attempts += 1
      if attempts <= enumeration_retry_count
        sleep(enumeration_retry_sleep(attempts))
        retry
      end

      @enumeration_errors << enumeration_error_row(directory, "readdir", error.class.name, error.message)
      nil
    end
  end

  def enumeration_retry_count
    value = Integer(ENV.fetch("CORPUS_METADATA_AUDIT_ENUMERATION_RETRIES", "3"))
    value.negative? ? 0 : value
  rescue ArgumentError, TypeError
    3
  end

  def enumeration_retry_sleep(attempt)
    base = Float(ENV.fetch("CORPUS_METADATA_AUDIT_ENUMERATION_RETRY_SLEEP", "0.25"))
    base = 0.25 if base.negative?
    base * attempt
  rescue ArgumentError, TypeError
    0.25 * attempt
  end

  def enumeration_error_row(path, operation, error_class, message)
    path = Pathname(path.to_s)
    relative = if path.absolute? && path.to_s.start_with?(@corpus_root.to_s)
      path.relative_path_from(@corpus_root).to_s.tr("\\", "/")
    else
      path.to_s.tr("\\", "/")
    end

    {
      path: relative,
      operation: operation,
      error_class: error_class,
      message: message
    }
  end

  def scan_file(path)
    relative = path.relative_path_from(@corpus_root).to_s.tr("\\", "/")
    header_rows = []
    malformed_rows = []
    body_start_line = nil

    path.open("r:bom|utf-8", invalid: :replace, undef: :replace, replace: "�") do |file|
      file.each_line.with_index(1) do |line, line_number|
        clean = line.delete_prefix(BOM).chomp

        if COMMENT_PATTERN.match?(clean)
          if (match = HEADER_PATTERN.match(clean))
            header_rows << [line_number, match[1].strip, match[2].strip]
          else
            malformed_rows << [line_number, clean]
          end
          next
        end

        if clean.strip.empty? && body_start_line.nil?
          next
        end

        body_start_line = line_number
        break unless @scan_all_comments
      end
    end

    duplicate_keys = duplicate_key_counts(header_rows)
    record_file(relative, header_rows, malformed_rows, duplicate_keys, body_start_line)
    header_rows.each { |line_number, key, value| record_metadata(relative, line_number, key, value) }
    malformed_rows.each do |line_number, content|
      @malformed << { path: relative, line_number: line_number, content: content }
    end
    duplicate_keys.each do |key, count|
      values = header_rows.select { |_line, raw_key, _value| raw_key == key }.map { |_line, _raw_key, value| value }
      @duplicates << { path: relative, key: key, count: count, values: values.join(" | ") }
    end
  rescue Errno::ENOENT, Errno::EACCES, Errno::EIO, Errno::ENAMETOOLONG, EncodingError => error
    @read_errors << { path: relative, operation: "read", error_class: error.class.name, message: error.message }
  end

  def duplicate_key_counts(header_rows)
    counts = Hash.new(0)
    header_rows.each { |_line, key, _value| counts[key] += 1 }
    counts.select { |_key, count| count > 1 }
  end

  def record_file(relative, header_rows, malformed_rows, duplicate_keys, body_start_line)
    parent = File.dirname(relative)
    folder = @folder_stats[parent]
    folder[:files] += 1
    folder[:metadata_files] += 1 unless header_rows.empty?
    header_rows.each { |_line, key, _value| folder[:keys][key] += 1 }

    @files << {
      path: relative,
      parent_folder: parent,
      file_name: File.basename(relative),
      metadata_rows: header_rows.length,
      unique_keys: header_rows.map { |_line, key, _value| key }.uniq.length,
      duplicate_keys: duplicate_keys.keys.join(" | "),
      malformed_header_rows: malformed_rows.length,
      body_start_line: body_start_line
    }
  end

  def record_metadata(relative, line_number, raw_key, value)
    canonical = canonical_key(raw_key)
    key = [raw_key, canonical]
    stats = (@field_stats[key] ||= FieldStats.new(
      raw_key: raw_key,
      canonical_key: canonical,
      files: Set.new,
      occurrences: 0,
      non_blank: 0,
      blank: 0,
      unique_values: Set.new,
      sample_values: [],
      sample_paths: []
    ))

    stats.files << relative
    stats.occurrences += 1
    if value.empty?
      stats.blank += 1
    else
      stats.non_blank += 1
      stats.unique_values << value
      stats.sample_values << value if stats.sample_values.length < MAX_SAMPLE_VALUES && !stats.sample_values.include?(value)
    end
    stats.sample_paths << relative if stats.sample_paths.length < MAX_SAMPLE_PATHS && !stats.sample_paths.include?(relative)

    @canonical_groups[canonical][raw_key] += 1
    @value_counts[raw_key][value] += 1
    if @value_paths[raw_key][value].length < MAX_VALUE_SAMPLE_PATHS
      @value_paths[raw_key][value] << relative unless @value_paths[raw_key][value].include?(relative)
    end
    record_separators(raw_key, value, relative)

    return unless @include_rows

    @rows << {
      path: relative,
      line_number: line_number,
      raw_key: raw_key,
      canonical_key: canonical,
      value: value,
      value_sha256: Digest::SHA256.hexdigest(value)
    }
  end

  def record_separators(raw_key, value, relative)
    SEPARATORS.each do |separator, label|
      next unless value.include?(separator)

      @separator_counts[raw_key][separator] += value.scan(separator).length
      @separator_samples[raw_key][separator] ||= { label: label, sample_value: value, sample_path: relative }
    end
  end

  def canonical_key(raw_key)
    raw_key.to_s.strip.upcase.gsub(/[[:space:]\-]+/, "_").gsub(/[^[:alnum:]_]/, "_").gsub(/_+/, "_").delete_prefix("_").delete_suffix("_")
  end

  def write_reports(started:, finished:, total_files_seen:)
    write_csv("fields.csv", field_rows)
    write_csv("canonical_key_groups.csv", canonical_group_rows)
    write_csv("field_values.csv", value_rows)
    write_csv("field_separators.csv", separator_rows)
    write_csv("files.csv", @files)
    write_csv("duplicate_headers.csv", @duplicates)
    write_csv("malformed_headers.csv", @malformed)
    write_csv("read_errors.csv", @read_errors)
    write_csv("enumeration_errors.csv", @enumeration_errors)
    write_csv("folder_key_counts.csv", folder_rows)
    write_csv("metadata_rows.csv", @rows) if @include_rows
    write_json_summary(started: started, finished: finished, total_files_seen: total_files_seen)
    write_markdown_summary(started: started, finished: finished, total_files_seen: total_files_seen)
  end

  def field_rows
    @field_stats.values.sort_by { |stats| [stats.canonical_key, stats.raw_key] }.map do |stats|
      {
        raw_key: stats.raw_key,
        canonical_key: stats.canonical_key,
        files: stats.files.length,
        occurrences: stats.occurrences,
        non_blank: stats.non_blank,
        blank: stats.blank,
        unique_values: stats.unique_values.length,
        sample_values: stats.sample_values.join(" | "),
        sample_paths: stats.sample_paths.join(" | ")
      }
    end
  end

  def canonical_group_rows
    @canonical_groups.sort_by { |canonical, _raws| canonical }.map do |canonical, raws|
      raw_summary = raws.sort_by { |raw, count| [-count, raw] }.map { |raw, count| "#{raw}=#{count}" }
      {
        canonical_key: canonical,
        raw_key_count: raws.length,
        total_occurrences: raws.values.sum,
        raw_keys: raw_summary.join(" | ")
      }
    end
  end

  def value_rows
    @value_counts.flat_map do |raw_key, counts|
      counts.sort_by { |value, count| [-count, value] }.map do |value, count|
        {
          raw_key: raw_key,
          value: value,
          count: count,
          value_sha256: Digest::SHA256.hexdigest(value),
          sample_paths: @value_paths[raw_key][value].join(" | ")
        }
      end
    end.sort_by { |row| [row[:raw_key], -row[:count], row[:value]] }
  end

  def separator_rows
    @separator_counts.flat_map do |raw_key, counts|
      counts.map do |separator, count|
        sample = @separator_samples[raw_key][separator]
        {
          raw_key: raw_key,
          separator: separator,
          separator_name: sample[:label],
          occurrences: count,
          sample_value: sample[:sample_value],
          sample_path: sample[:sample_path]
        }
      end
    end.sort_by { |row| [row[:raw_key], -row[:occurrences], row[:separator]] }
  end

  def folder_rows
    @folder_stats.map do |folder, stats|
      {
        folder: folder,
        files: stats[:files],
        files_with_metadata: stats[:metadata_files],
        key_count: stats[:keys].length,
        keys: stats[:keys].sort_by { |key, count| [-count, key] }.map { |key, count| "#{key}=#{count}" }.join(" | ")
      }
    end.sort_by { |row| row[:folder] }
  end

  CSV_HEADERS = {
    "fields.csv" => %i[raw_key canonical_key files occurrences non_blank blank unique_values sample_values sample_paths],
    "canonical_key_groups.csv" => %i[canonical_key raw_key_count total_occurrences raw_keys],
    "field_values.csv" => %i[raw_key value count value_sha256 sample_paths],
    "field_separators.csv" => %i[raw_key separator separator_name occurrences sample_value sample_path],
    "files.csv" => %i[path parent_folder file_name metadata_rows unique_keys duplicate_keys malformed_header_rows body_start_line],
    "duplicate_headers.csv" => %i[path key count values],
    "malformed_headers.csv" => %i[path line_number content],
    "read_errors.csv" => %i[path operation error_class message],
    "enumeration_errors.csv" => %i[path operation error_class message],
    "folder_key_counts.csv" => %i[folder files files_with_metadata key_count keys],
    "metadata_rows.csv" => %i[path line_number raw_key canonical_key value value_sha256],
    "txt_files.csv" => %i[path]
  }.freeze

  def write_csv(name, rows)
    path = @output_root.join(name)
    headers = rows.first&.keys || CSV_HEADERS.fetch(name, [])
    CSV.open(path, "w", write_headers: true, headers: headers, encoding: "UTF-8") do |csv|
      rows.each { |row| csv << headers.map { |key| row[key] } }
    end
  end

  def write_json_summary(started:, finished:, total_files_seen:)
    summary = summary_hash(started: started, finished: finished, total_files_seen: total_files_seen)
    @output_root.join("summary.json").write(JSON.pretty_generate(summary))
  end

  def write_markdown_summary(started:, finished:, total_files_seen:)
    summary = summary_hash(started: started, finished: finished, total_files_seen: total_files_seen)
    lines = []
    lines << "# Corpus metadata audit"
    lines << ""
    lines << "- Started: `#{summary[:started_at]}`"
    lines << "- Finished: `#{summary[:finished_at]}`"
    lines << "- Duration seconds: `#{summary[:duration_seconds]}`"
    lines << "- Corpus root: `#{summary[:corpus_root]}`"
    lines << "- Text files scanned: `#{summary[:text_files_scanned]}`"
    lines << "- Files with metadata: `#{summary[:files_with_metadata]}`"
    lines << "- Raw metadata keys: `#{summary[:raw_key_count]}`"
    lines << "- Canonical metadata keys: `#{summary[:canonical_key_count]}`"
    lines << "- Duplicate header rows: `#{summary[:duplicate_header_files]}` files"
    lines << "- Malformed header rows: `#{summary[:malformed_header_rows]}`"
    lines << "- Read errors: `#{summary[:read_errors]}`"
    lines << "- Enumeration errors: `#{summary[:enumeration_errors]}`"
    lines << "- Enumeration complete: `#{summary[:enumeration_complete]}`"
    lines << "- Run error: `#{summary[:run_error] || "none"}`"
    lines << ""
    lines << "## Output files"
    lines << ""
    output_descriptions.each do |name, description|
      next if name == "metadata_rows.csv" && !@include_rows

      lines << "- `#{name}` — #{description}"
    end
    @output_root.join("REPORT.md").write(lines.join("\n") + "\n")
  end

  def summary_hash(started:, finished:, total_files_seen:)
    {
      version: 1,
      started_at: started.iso8601,
      finished_at: finished.iso8601,
      duration_seconds: (finished - started).round(3),
      corpus_root: @corpus_root.to_s,
      output_root: @output_root.to_s,
      text_files_scanned: total_files_seen,
      files_with_metadata: @files.count { |row| row[:metadata_rows].positive? },
      raw_key_count: @field_stats.length,
      canonical_key_count: @canonical_groups.length,
      field_value_rows: @value_counts.sum { |_key, values| values.length },
      separator_rows: @separator_counts.sum { |_key, values| values.length },
      duplicate_header_files: @duplicates.map { |row| row[:path] }.uniq.length,
      duplicate_header_rows: @duplicates.length,
      malformed_header_rows: @malformed.length,
      read_errors: @read_errors.length,
      enumeration_errors: @enumeration_errors.length,
      enumeration_complete: @enumeration_errors.empty?,
      run_error: @run_error,
      include_rows: @include_rows,
      scan_all_comments: @scan_all_comments
    }
  end

  def output_descriptions
    {
      "fields.csv" => "one row per raw metadata key, with counts and samples",
      "canonical_key_groups.csv" => "groups raw keys by normalised key to catch spelling/punctuation variants",
      "field_values.csv" => "one row per field value, with counts and sample files",
      "field_separators.csv" => "separator punctuation found inside values, e.g. comma variants and semicolons",
      "files.csv" => "one row per text file scanned, with metadata row counts and duplicate-key summary",
      "duplicate_headers.csv" => "files where the same metadata key appears more than once",
      "malformed_headers.csv" => "leading # comment rows that do not match KEY: value",
      "read_errors.csv" => "text files that were discovered but could not be read",
      "txt_files.csv" => "text files discovered during enumeration; written before the slower metadata scan starts",
      "progress.json" => "latest progress checkpoint; useful if a long run is interrupted",
      "enumeration_errors.csv" => "directories/files the OS refused to enumerate or stat",
      "folder_key_counts.csv" => "metadata-key counts grouped by parent folder, useful for JSON sidecar planning",
      "metadata_rows.csv" => "optional full row-level dump; written only with --include-rows",
      "summary.json" => "machine-readable run summary",
      "REPORT.md" => "human-readable summary"
    }
  end
end

options = {
  corpus_root: Pathname(__dir__).join("../../corpus").expand_path,
  output_root: Pathname("tmp/corpus_metadata_audit/#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}").expand_path,
  include_rows: false,
  max_files: nil,
  scan_all_comments: false,
  strict_enumeration: false,
  file_list: nil
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby script/corpus_metadata_audit.rb [options]"
  opts.on("--corpus-root PATH", "Corpus root directory; default: ../corpus from viewer root") { |value| options[:corpus_root] = Pathname(value) }
  opts.on("--output PATH", "Output directory; default: tmp/corpus_metadata_audit/<timestamp>") { |value| options[:output_root] = Pathname(value) }
  opts.on("--include-rows", "Also write metadata_rows.csv with one row per header entry") { options[:include_rows] = true }
  opts.on("--max-files N", Integer, "Limit scan for testing") { |value| options[:max_files] = value }
  opts.on("--scan-all-comments", "Experimental: continue scanning later # comments instead of only leading header block") { options[:scan_all_comments] = true }
  opts.on("--strict-enumeration", "Continue scanning, write all possible reports, then exit 2 if any directory/file could not be listed") { options[:strict_enumeration] = true }
  opts.on("--file-list PATH", "Read newline-separated .txt paths from PATH instead of walking the corpus tree") { |value| options[:file_list] = Pathname(value) }
  opts.on("-h", "--help", "Show help") do
    puts opts
    exit 0
  end
end.parse!

CorpusMetadataAudit.new(**options).run
