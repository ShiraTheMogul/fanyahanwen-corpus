#!/usr/bin/env ruby
# encoding: UTF-8
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
require "zlib"

# Read-only reconciliation audit for the Fanya Hanwen Corpus.
#
# It answers the questions left uncertain after the JSON migration:
#   * Is metadata.json in the place the viewer actually reads?
#   * Does every text have a stable work ID and document ID?
#   * Does metadata list the file that physically exists?
#   * Is an apparent fallback ID a corpus defect or only a stale manifest?
#   * Are any old # KEY: value headers or backup files still present?
#   * Does the Shang object-centred layout appear to have been applied?
#   * What atlas work is genuinely outstanding?
#
# The script never edits the corpus, viewer source, manifest, or database. It
# writes only to --output.
class ProjectStateAudit
  VERSION = 3
  DEFAULT_PROGRESS_EVERY = 5_000
  DEFAULT_READ_RETRIES = 3
  DEFAULT_HEADER_BYTES = 65_536
  FALLBACK_ID_PATTERN = /\A[0-9a-f]{24}\z/i
  NUMERIC_ID_PATTERN = /\A\d+\z/
  HEADER_PATTERN = /\A#\s*([^:：]+?)\s*[:：]\s*(.*?)\s*\z/
  SKIP_DIRECTORY_NAMES = %w[.git .svn node_modules].freeze
  READ_ERRORS = [
    Errno::EIO,
    Errno::EACCES,
    Errno::ENOENT,
    Errno::ENOTDIR,
    Errno::ENAMETOOLONG,
    Errno::ELOOP,
    Encoding::CompatibilityError,
    SystemCallError
  ].freeze

  MetadataRecord = Struct.new(
    :relative_path,
    :directory,
    :valid,
    :error,
    :data,
    :work_id,
    :title,
    :documents,
    :by_path,
    :by_file,
    keyword_init: true
  )

  DocumentReference = Struct.new(
    :key,
    :metadata_path,
    :metadata_directory,
    :source,
    :index,
    :work_id,
    :document_id,
    :title,
    :file,
    :path,
    :resolved_path,
    :resolution_basis,
    :exists,
    keyword_init: true
  )

  def initialize(argv)
    @options = {
      viewer_root: Pathname.pwd,
      corpus_root: nil,
      output_root: nil,
      manifest_path: nil,
      use_manifest: true,
      atlas: true,
      shang: true,
      strict: false,
      scope: "",
      clean_only: false,
      raw_only: false,
      max_files: 0,
      progress_every: DEFAULT_PROGRESS_EVERY,
      read_retries: DEFAULT_READ_RETRIES,
      header_bytes: DEFAULT_HEADER_BYTES
    }
    parse_options!(argv)
    resolve_paths!

    @started_at = Time.now.utc
    @counts = Hash.new(0)
    @txt_paths = []
    @metadata_paths = []
    @metadata_by_directory = {}
    @document_references = {}
    @matched_document_references = Set.new
    @manifest_by_path = {}
    @manifest_seen_paths = Set.new
    @fallback_groups = Hash.new { |hash, key| hash[key] = { count: 0, title: "", metadata_path: "", work_id: "", source_bucket: "", document_role: "" } }
    @directories_seen = Set.new
    @phase_timings = {}
    @shang_scan = Hash.new(0)
    @enumeration_errors = []
    @read_errors = []
    @confirmed_errors = 0
    @review_findings = 0

    @work_id_first = {}
    @work_id_duplicates = Hash.new { |hash, key| hash[key] = [] }
    @document_id_first = {}
    @document_id_duplicates = Hash.new { |hash, key| hash[key] = [] }
  end

  def run
    validate!
    prepare_output!
    open_writers!

    log "project-state audit v#{VERSION}"
    log "viewer root: #{@viewer_root}"
    log "corpus root: #{@corpus_root}"
    log "scan root: #{@scan_root}"
    log "filters: #{scan_filter_description}"
    log "output root: #{@output_root}"

    timed("manifest load") { load_manifest } if @options[:use_manifest]
    timed("corpus enumeration") { enumerate_corpus }
    timed("metadata parsing") { parse_metadata_files }
    timed("text reconciliation") { audit_text_files }
    if complete_corpus_scan?
      timed("metadata-reference finish") { finish_document_reference_audit }
    else
      @counts["metadata_reference_finish_skipped_partial_scan"] = 1
    end
    timed("manifest finish") { finish_manifest_audit } if @manifest_loaded && complete_corpus_scan?
    @counts["limited_scan"] = 1 if partial_scan?
    timed("duplicate reports") { write_duplicate_reports }
    timed("atlas audit") { audit_atlas } if @options[:atlas]
    timed("Shang audit") { audit_shang } if @options[:shang]
    timed("fallback summaries") { write_fallback_groups }
    write_summaries(partial: partial_scan?)

    log "DONE: #{@counts['txt_files']} text files, #{@counts['metadata_files']} metadata files"
    log "confirmed errors: #{@confirmed_errors}; review findings: #{@review_findings}"
    log "reports: #{@output_root}"

    exit 2 if @options[:strict] && @confirmed_errors.positive?
  rescue Interrupt
    log "interrupted; writing partial summary"
    write_summaries(partial: true) if @output_root&.directory?
    raise
  rescue StandardError => error
    @fatal_error = "#{error.class}: #{error.message}"
    warn "[project-state-audit] FATAL #{@fatal_error}"
    warn error.backtrace.first(12).join("\n")
    write_summaries(partial: true) if @output_root&.directory?
    raise
  ensure
    close_writers!
  end

  private

  def parse_options!(argv)
    OptionParser.new do |parser|
      parser.banner = "Usage: ruby script/project_state_audit.rb [options]"

      parser.on("--viewer-root PATH", "Viewer root (default: current directory)") do |value|
        @options[:viewer_root] = Pathname.new(value)
      end
      parser.on("--corpus-root PATH", "Corpus root (default: VIEWER_ROOT/../corpus)") do |value|
        @options[:corpus_root] = Pathname.new(value)
      end
      parser.on("--scope PATH", "Only scan this corpus-relative subtree, for example 維基大典/clean") do |value|
        @options[:scope] = normalize_cli_path(value)
      end
      parser.on("--clean-only", "Scan only corpus clean/ trees; raw/ trees are pruned") do
        @options[:clean_only] = true
      end
      parser.on("--raw-only", "Scan only corpus raw/ trees; clean/ trees are pruned") do
        @options[:raw_only] = true
      end
      parser.on("--output PATH", "Output folder (default: VIEWER_ROOT/tmp/project_state_audit/full_TIMESTAMP)") do |value|
        @options[:output_root] = Pathname.new(value)
      end
      parser.on("--manifest PATH", "Explicit manifest.json.gz or manifest.json") do |value|
        @options[:manifest_path] = Pathname.new(value)
      end
      parser.on("--no-manifest", "Do not compare against the search manifest") do
        @options[:use_manifest] = false
      end
      parser.on("--skip-atlas", "Skip viewer atlas source checks") do
        @options[:atlas] = false
      end
      parser.on("--skip-shang", "Skip Shang-layout checks") do
        @options[:shang] = false
      end
      parser.on("--max-files N", Integer, "Stop after discovering N .txt files; useful only for testing") do |value|
        @options[:max_files] = [value, 0].max
      end
      parser.on("--progress-every N", Integer, "Print progress every N records (default: #{DEFAULT_PROGRESS_EVERY})") do |value|
        @options[:progress_every] = [value, 1].max
      end
      parser.on("--read-retries N", Integer, "Filesystem read attempts (default: #{DEFAULT_READ_RETRIES})") do |value|
        @options[:read_retries] = [value, 1].max
      end
      parser.on("--header-bytes N", Integer, "Bytes read for legacy-header checks (default: #{DEFAULT_HEADER_BYTES})") do |value|
        @options[:header_bytes] = [value, 1_024].max
      end
      parser.on("--strict", "Exit with status 2 when confirmed structural errors exist") do
        @options[:strict] = true
      end
      parser.on("-h", "--help", "Show this help") do
        puts parser
        exit 0
      end
    end.parse!(argv)
  end

  def resolve_paths!
    @viewer_root = @options[:viewer_root].expand_path
    @corpus_root = (@options[:corpus_root] || @viewer_root.join("..", "corpus")).expand_path
    @scope = normalize_relative(@options[:scope])
    @scan_root = @scope.empty? ? @corpus_root : @corpus_root.join(@scope).expand_path
    stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    @output_root = (@options[:output_root] || @viewer_root.join("tmp", "project_state_audit", "full_#{stamp}")).expand_path
    @manifest_path = (@options[:manifest_path] || @viewer_root.join("storage", "corpus_search", "manifest.json.gz")).expand_path
  end

  def validate!
    raise ArgumentError, "Viewer root does not exist: #{@viewer_root}" unless @viewer_root.directory?
    raise ArgumentError, "Corpus root does not exist: #{@corpus_root}" unless @corpus_root.directory?
    raise ArgumentError, "Scope does not exist: #{@scan_root}" unless @scan_root.directory?
    raise ArgumentError, "--clean-only and --raw-only cannot be used together" if @options[:clean_only] && @options[:raw_only]
    scope_bucket = source_bucket_for(join_relative(@scope, "__scope_probe__")) unless @scope.empty?
    if @options[:clean_only] && scope_bucket == "raw"
      raise ArgumentError, "--clean-only conflicts with raw scope #{@scope}"
    end
    if @options[:raw_only] && scope_bucket == "clean"
      raise ArgumentError, "--raw-only conflicts with clean scope #{@scope}"
    end
    unless safely_under_root?(@scan_root, @corpus_root)
      raise ArgumentError, "Scope escapes the corpus root: #{@scan_root}"
    end
    if @output_root.to_s == @corpus_root.to_s || @output_root.to_s.start_with?("#{@corpus_root}/")
      raise ArgumentError, "Output must not be inside the corpus: #{@output_root}"
    end
  end

  def prepare_output!
    FileUtils.mkdir_p(@output_root)
  end

  def open_writers!
    @writers = {}
    open_csv("documents.csv", %w[
      path size_bytes source_bucket document_role metadata_expected metadata_lookup metadata_path metadata_match work_id work_id_status
      document_id document_id_status legacy_header legacy_keys manifest_presence manifest_id
      manifest_work_id manifest_id_status manifest_work_id_status notes
    ])
    open_csv("metadata_files.csv", %w[
      metadata_path directory valid error work_id work_id_status title is_compilation
      top_level_documents edition_documents total_documents direct_txt_files
    ])
    open_csv("metadata_documents.csv", %w[
      reference_key metadata_path source index work_id document_id document_id_status title
      file path resolved_path resolution_basis exists
    ])
    open_csv("structural_findings.csv", %w[severity kind path related_path work_id document_id message])
    open_csv("manifest_findings.csv", %w[severity kind path metadata_document_id manifest_id metadata_work_id manifest_work_id message])
    open_csv("backup_files.csv", %w[path size_bytes extension])
    open_csv("enumeration_errors.csv", %w[operation path error_class message])
    open_csv("read_errors.csv", %w[operation path error_class message])
    open_csv("atlas_findings.csv", %w[severity kind path line entry_id name period_ids message])
    open_csv("atlas_multi_period_entries.csv", %w[entry_id name period_count period_ids metadata_path])
    open_csv("atlas_same_name_entries.csv", %w[name entry_count entry_ids metadata_paths])
    open_csv("shang_findings.csv", %w[severity kind path count message])
  end

  def open_csv(name, headers)
    file = CSV.open(@output_root.join(name), "w", encoding: "UTF-8", write_headers: true, headers: headers)
    @writers[name] = file
  end

  def csv(name, row)
    @writers.fetch(name) << row
  end

  def close_writers!
    @writers&.each_value(&:close)
  end

  def log(message)
    elapsed = Time.now.utc - @started_at
    warn format("[project-state-audit %s +%8.1fs] %s", Time.now.utc.strftime("%H:%M:%S"), elapsed, message)
  end

  def timed(label)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    log "BEGIN #{label}"
    yield
  ensure
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    @phase_timings[label] = elapsed.round(3)
    log format("END %s (%.1fs)", label, elapsed)
  end

  def partial_scan?
    @options[:max_files].positive? || !@scope.empty? || @options[:clean_only] || @options[:raw_only]
  end

  def complete_corpus_scan?
    !partial_scan?
  end

  def complete_shang_scan?
    return false if @options[:max_files].positive? || @options[:raw_only]

    shang = "中國漢文/clean/商殷朝"
    @scope.empty? || shang == @scope || shang.start_with?("#{@scope}/")
  end

  def scan_filter_description
    rows = []
    rows << "scope=#{@scope}" unless @scope.empty?
    rows << "clean-only" if @options[:clean_only]
    rows << "raw-only" if @options[:raw_only]
    rows << "max-files=#{@options[:max_files]}" if @options[:max_files].positive?
    rows.empty? ? "full corpus" : rows.join(", ")
  end

  def progress?(count)
    (count % @options[:progress_every]).zero?
  end

  # ----------------------------- manifest ---------------------------------

  def load_manifest
    unless @manifest_path.file?
      log "manifest not found at #{@manifest_path}; corpus audit will continue without it"
      @counts["manifest_missing"] = 1
      return
    end

    log "loading manifest #{@manifest_path}"
    payload = if @manifest_path.extname == ".gz"
      Zlib::GzipReader.open(@manifest_path.to_s, &:read)
    else
      @manifest_path.read(encoding: "UTF-8")
    end
    parsed = JSON.parse(payload)
    documents = Array(parsed["documents"])

    documents.each_with_index do |document, index|
      path = normalize_relative(document["path"])
      next if path.empty?

      if @manifest_by_path.key?(path)
        finding(
          severity: "error",
          kind: "duplicate_manifest_path",
          path: path,
          message: "The manifest contains the same path more than once."
        )
      else
        @manifest_by_path[path] = {
          "id" => document["id"].to_s,
          "work_id" => document["work_id"].to_s,
          "title" => document["title"].to_s,
          "document_role" => document["document_role"].to_s,
          "searchable_body" => document["searchable_body"]
        }
      end
      log "manifest rows loaded: #{index + 1}/#{documents.length}" if progress?(index + 1)
    end

    @manifest_loaded = true
    @counts["manifest_documents"] = @manifest_by_path.length
    @manifest_generated_at = parsed["generated_at"].to_s
    @manifest_version = parsed["version"]
    log "manifest loaded: #{@manifest_by_path.length} documents; generated #{@manifest_generated_at}"
  rescue JSON::ParserError, Zlib::GzipFile::Error, SystemCallError => error
    @counts["manifest_read_error"] = 1
    record_read_error("manifest", @manifest_path, error)
    log "manifest could not be read; continuing without comparison"
  end

  # ---------------------------- enumeration -------------------------------

  def enumerate_corpus
    log "phase 1: enumerating corpus"
    stack = [@scan_root]
    directories = 0
    limit_reached = false

    until stack.empty?
      directory = stack.pop
      relative_directory = relative_to_corpus(directory)
      @directories_seen << relative_directory
      entries = safe_children(directory)
      directories += 1
      @counts["directories"] = directories
      if progress?(directories)
        log "enumeration: #{directories} directories, #{@txt_paths.length} texts, #{@metadata_paths.length} metadata files"
      end

      entries.each do |name|
        next if name.start_with?(".")
        next if SKIP_DIRECTORY_NAMES.include?(name)

        absolute = directory.join(name)
        begin
          stat = absolute.lstat
          next if stat.symlink?

          relative = relative_to_corpus(absolute)
          if stat.directory?
            stack << absolute if !limit_reached && descend_into_directory?(relative)
          elsif stat.file?
            lower = name.downcase
            if lower == "metadata.json"
              @metadata_paths << relative if path_selected?(relative)
              track_shang_path(relative, :metadata)
            elsif lower.end_with?(".txt")
              next unless path_selected?(relative)
              unless limit_reached
                @txt_paths << relative
                track_shang_path(relative, :text)
                limit_reached = @options[:max_files].positive? && @txt_paths.length >= @options[:max_files]
              end
            elsif backup_name?(lower) && path_selected?(relative)
              @counts["backup_files"] += 1
              @counts["backup_bytes"] += stat.size
              csv("backup_files.csv", {
                "path" => relative,
                "size_bytes" => stat.size,
                "extension" => backup_extension(lower)
              })
            end
          end
        rescue *READ_ERRORS => error
          record_enumeration_error("stat", absolute, error)
        end
      end

      stack.clear if limit_reached
    end

    @txt_paths.sort!
    @metadata_paths.sort!
    @txt_count_by_directory = Hash.new(0)
    @txt_paths.each do |path|
      directory = normalize_relative(File.dirname(path))
      directory = "" if directory == "."
      @txt_count_by_directory[directory] += 1
      source_bucket = source_bucket_for(path)
      role = document_role_for(path)
      @counts["texts_bucket_#{source_bucket}"] += 1
      @counts["texts_role_#{role}"] += 1
    end
    @counts["txt_files"] = @txt_paths.length
    @counts["metadata_files"] = @metadata_paths.length
    log "enumeration complete: #{@txt_paths.length} texts, #{@metadata_paths.length} metadata files, #{@counts['backup_files']} backups"
  end

  def safe_children(directory)
    attempts = 0
    begin
      attempts += 1
      Dir.children(directory.to_s).map { |name| name.dup.force_encoding(Encoding::UTF_8) }
    rescue *READ_ERRORS => error
      if attempts < @options[:read_retries]
        sleep(0.25 * attempts)
        retry
      end
      record_enumeration_error("readdir", directory, error)
      []
    end
  end

  def descend_into_directory?(relative)
    bucket = source_bucket_for(relative)
    return false if @options[:clean_only] && bucket == "raw"
    return false if @options[:raw_only] && bucket == "clean"

    true
  end

  def path_selected?(relative)
    bucket = source_bucket_for(relative)
    return bucket == "clean" if @options[:clean_only]
    return bucket == "raw" if @options[:raw_only]

    true
  end

  def source_bucket_for(relative)
    parts = normalize_relative(relative).split("/")
    bucket = parts[1].to_s.downcase
    return bucket if %w[clean raw].include?(bucket)

    "other"
  end

  def document_role_for(relative)
    bucket = source_bucket_for(relative)
    return "raw" if bucket == "raw"

    parts = normalize_relative(relative).split("/").map(&:downcase)
    return "translation" if (parts & %w[translation translations]).any?
    return "annotation" if (parts & %w[annotation annotations]).any?
    return "variant" if (parts & %w[variant variants]).any?
    return "canonical" if bucket == "clean"

    "other"
  end

  def metadata_expected_for?(relative)
    document_role_for(relative) != "raw"
  end

  def track_shang_path(relative, kind)
    path = normalize_relative(relative)
    base = "中國漢文/clean/商殷朝"
    return unless path == base || path.start_with?("#{base}/")

    @shang_scan["seen"] += 1
    target_prefixes = [
      "#{base}/商/甲骨文", "#{base}/商/金文",
      "#{base}/周方/甲骨文", "#{base}/周方/金文",
      "#{base}/子方/甲骨文", "#{base}/子方/金文",
      "#{base}/土方/甲骨文", "#{base}/土方/金文"
    ]
    if target_prefixes.any? { |prefix| path == prefix || path.start_with?("#{prefix}/") }
      @shang_scan[kind == :metadata ? "target_metadata" : "target_texts"] += 1
    end

    h3 = "#{base}/商/甲骨文/殷墟/花園莊東地/H3"
    if path == h3 || path.start_with?("#{h3}/")
      @shang_scan[kind == :metadata ? "h3_metadata" : "h3_texts"] += 1
    end

    components = path.split("/")
    legacy = path.start_with?("#{base}/甲骨/") ||
      components.include?("花園庄（洹北）") || components.include?("花園莊（洹北）")
    @shang_scan[kind == :metadata ? "legacy_metadata" : "legacy_texts"] += 1 if legacy

    @shang_scan["huadong_zero_object_paths"] += 1 if components.include?("花東0")
    if kind == :text && File.basename(path).match?(/\A花東0(?:[._]|\z)/)
      @shang_scan["huadong_zero_source_alias_files"] += 1
    end
  end

  def backup_name?(lower_name)
    lower_name.end_with?(".bak", ".bak2", ".backup", "~")
  end

  def backup_extension(lower_name)
    return ".bak2" if lower_name.end_with?(".bak2")
    return ".bak" if lower_name.end_with?(".bak")
    return ".backup" if lower_name.end_with?(".backup")
    return "~" if lower_name.end_with?("~")

    ""
  end

  # ------------------------------ metadata --------------------------------

  def parse_metadata_files
    log "phase 2: parsing metadata"

    @metadata_paths.each_with_index do |relative, index|
      record = parse_metadata(relative)
      @metadata_by_directory[record.directory] = record
      write_metadata_record(record)
      record.data = nil if record.valid
      log "metadata: #{index + 1}/#{@metadata_paths.length}" if progress?(index + 1)
    end

    log "metadata parsing complete: #{@counts['valid_metadata']} valid; #{@counts['invalid_metadata']} invalid"
  end

  def metadata_for_directory(directory)
    return @metadata_by_directory[directory] if @metadata_by_directory.key?(directory)

    relative = join_relative(directory, "metadata.json")
    absolute = @corpus_root.join(relative)
    return nil unless absolute.file?

    record = parse_metadata(relative)
    @metadata_by_directory[directory] = record
    @metadata_paths << relative unless @metadata_paths.include?(relative)
    @counts["metadata_files"] = @metadata_paths.length
    write_metadata_record(record)
    record.data = nil if record.valid
    record
  rescue *READ_ERRORS => error
    record_read_error("metadata_probe", absolute, error)
    nil
  end

  def parse_metadata(relative)
    absolute = @corpus_root.join(relative)
    directory = normalize_relative(File.dirname(relative))
    directory = "" if directory == "."

    data = JSON.parse(absolute.read(encoding: "UTF-8"))
    unless data.is_a?(Hash)
      raise JSON::ParserError, "top-level JSON value is #{data.class}, not an object"
    end

    documents = []
    Array(data["documents"]).each_with_index do |document, index|
      documents << build_document_reference(
        metadata_path: relative,
        metadata_directory: directory,
        source: "documents",
        index: index,
        work_id: data["work_id"],
        document: document
      )
    end
    Array(data["editions"]).each_with_index do |edition, edition_index|
      next unless edition.is_a?(Hash)

      Array(edition["documents"]).each_with_index do |document, document_index|
        documents << build_document_reference(
          metadata_path: relative,
          metadata_directory: directory,
          source: "editions[#{edition_index}].documents",
          index: document_index,
          work_id: data["work_id"],
          document: document
        )
      end
    end

    by_path = Hash.new { |hash, key| hash[key] = [] }
    by_file = Hash.new { |hash, key| hash[key] = [] }
    documents.each do |document|
      by_path[document.resolved_path] << document unless document.resolved_path.to_s.empty?
      by_file[document.file] << document unless document.file.to_s.empty?
    end

    @counts["valid_metadata"] += 1
    MetadataRecord.new(
      relative_path: relative,
      directory: directory,
      valid: true,
      error: "",
      data: data,
      work_id: data["work_id"].to_s,
      title: first_present(data["work_base_title"], data["title"]),
      documents: documents,
      by_path: by_path,
      by_file: by_file
    )
  rescue JSON::ParserError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError, SystemCallError => error
    @counts["invalid_metadata"] += 1
    confirmed_error(
      kind: "invalid_metadata_json",
      path: relative,
      message: "#{error.class}: #{error.message}"
    )
    MetadataRecord.new(
      relative_path: relative,
      directory: directory,
      valid: false,
      error: "#{error.class}: #{error.message}",
      data: {},
      work_id: "",
      title: "",
      documents: [],
      by_path: {},
      by_file: {}
    )
  end

  def build_document_reference(metadata_path:, metadata_directory:, source:, index:, work_id:, document:)
    unless document.is_a?(Hash)
      document = { "_invalid_value" => document.inspect }
    end

    file = document["file"].to_s
    path = normalize_relative(document["path"])
    resolved_path, basis = resolve_document_path(metadata_directory, file, path)
    exists = !resolved_path.empty? && @corpus_root.join(resolved_path).file?
    key = "#{metadata_path}##{source}[#{index}]"

    reference = DocumentReference.new(
      key: key,
      metadata_path: metadata_path,
      metadata_directory: metadata_directory,
      source: source,
      index: index,
      work_id: work_id.to_s,
      document_id: document["document_id"].to_s,
      title: first_present(document["title"], document["page_title"], file.empty? ? File.basename(path, ".txt") : File.basename(file, ".txt")),
      file: file,
      path: path,
      resolved_path: resolved_path,
      resolution_basis: basis,
      exists: exists
    )
    @document_references[key] = reference
    reference
  end

  def resolve_document_path(metadata_directory, file, path)
    candidates = []
    unless path.empty?
      candidates << [path, "path_from_corpus_root"]
      candidates << [join_relative(metadata_directory, path), "path_from_metadata_folder"] unless path.start_with?("#{metadata_directory}/")
    end
    candidates << [join_relative(metadata_directory, file), "file_beside_metadata"] unless file.empty?

    candidates.each do |candidate, basis|
      next if candidate.empty?
      next unless safely_inside_corpus?(candidate)
      return [candidate, basis] if @corpus_root.join(candidate).file?
    end

    candidate, basis = candidates.find { |value, _| !value.empty? && safely_inside_corpus?(value) }
    [candidate.to_s, candidate ? "#{basis}_missing" : "unresolved"]
  end

  def safely_inside_corpus?(relative)
    clean = Pathname(relative).cleanpath.to_s.tr("\\", "/")
    clean != ".." && !clean.start_with?("../") && !Pathname(clean).absolute?
  end

  def write_metadata_record(record)
    direct_txt_count = @txt_count_by_directory.fetch(record.directory, 0)
    data = record.data
    top_level_count = Array(data["documents"]).length
    edition_count = Array(data["editions"]).sum { |edition| edition.is_a?(Hash) ? Array(edition["documents"]).length : 0 }

    work_status = id_status(record.work_id)
    register_id(:work, record.work_id, record.relative_path) unless record.work_id.empty?
    if record.valid && work_status != "numeric"
      review_finding(
        kind: record.work_id.empty? ? "metadata_missing_work_id" : "metadata_non_numeric_work_id",
        path: record.relative_path,
        work_id: record.work_id,
        message: "The metadata work_id is #{record.work_id.empty? ? 'missing' : 'not a numeric stable ID'}."
      )
    end

    csv("metadata_files.csv", {
      "metadata_path" => record.relative_path,
      "directory" => record.directory,
      "valid" => record.valid,
      "error" => record.error,
      "work_id" => record.work_id,
      "work_id_status" => work_status,
      "title" => record.title,
      "is_compilation" => data["is_compilation"] == true,
      "top_level_documents" => top_level_count,
      "edition_documents" => edition_count,
      "total_documents" => record.documents.length,
      "direct_txt_files" => direct_txt_count
    })

    record.documents.each do |document|
      doc_status = id_status(document.document_id)
      register_id(:document, document.document_id, document.key) unless document.document_id.empty?

      if doc_status != "numeric"
        review_finding(
          kind: document.document_id.empty? ? "metadata_document_missing_id" : "metadata_document_non_numeric_id",
          path: document.metadata_path,
          related_path: document.resolved_path,
          work_id: document.work_id,
          document_id: document.document_id,
          message: "A listed document has #{document.document_id.empty? ? 'no document_id' : 'a non-numeric document_id'}."
        )
      end

      unless document.exists
        confirmed_error(
          kind: "metadata_lists_missing_document",
          path: document.metadata_path,
          related_path: document.resolved_path,
          work_id: document.work_id,
          document_id: document.document_id,
          message: "metadata.json lists a document that does not exist at the resolved path."
        )
      end

      csv("metadata_documents.csv", {
        "reference_key" => document.key,
        "metadata_path" => document.metadata_path,
        "source" => document.source,
        "index" => document.index,
        "work_id" => document.work_id,
        "document_id" => document.document_id,
        "document_id_status" => doc_status,
        "title" => document.title,
        "file" => document.file,
        "path" => document.path,
        "resolved_path" => document.resolved_path,
        "resolution_basis" => document.resolution_basis,
        "exists" => document.exists
      })
    end
  end

  # ------------------------------- texts ----------------------------------

  def audit_text_files
    log "phase 3: reconciling physical texts, metadata, and manifest"

    @txt_paths.each_with_index do |relative, index|
      audit_text(relative)
      log "texts: #{index + 1}/#{@txt_paths.length}" if progress?(index + 1)
    end

    log "text reconciliation complete"
  end

  def audit_text(relative)
    absolute = @corpus_root.join(relative)
    stat = absolute.stat
    directory = normalize_relative(File.dirname(relative))
    directory = "" if directory == "."
    filename = File.basename(relative)
    source_bucket = source_bucket_for(relative)
    document_role = document_role_for(relative)
    metadata_expected = metadata_expected_for?(relative)
    direct_metadata = metadata_for_directory(directory)
    child_directory = join_relative(directory, File.basename(relative, File.extname(relative)))

    match = nil
    match_kind = ""
    lookup = metadata_expected ? "none" : "not_expected_raw"
    metadata = direct_metadata

    if direct_metadata
      lookup = direct_metadata.valid ? "direct_sibling" : "direct_sibling_invalid"
      match, match_kind = match_document(direct_metadata, relative, filename)
    end

    # A limited scan may stop before descending into same-named child folders.
    # Probe that exact metadata path directly so flat Wikisource layouts are not
    # misreported as having no metadata at all.
    child_metadata = nil
    if direct_metadata.nil? && match.nil?
      child_metadata = metadata_for_directory(child_directory)
      if child_metadata
        metadata = child_metadata
        match, match_kind = match_document(child_metadata, relative, filename)
        lookup = child_metadata.valid ? "metadata_in_same_named_child" : "metadata_in_same_named_child_invalid"
        review_finding(
          kind: "metadata_in_same_named_child",
          path: relative,
          related_path: child_metadata.relative_path,
          work_id: child_metadata.work_id,
          document_id: match&.document_id.to_s,
          message: "The text is outside the same-named work folder. Desired layout is folder/metadata.json plus folder/text.txt."
        )
        if child_metadata.valid && match.nil?
          review_finding(
            kind: "text_not_listed_by_child_metadata",
            path: relative,
            related_path: child_metadata.relative_path,
            work_id: child_metadata.work_id,
            message: "Same-named child metadata exists but does not identify the flat text by exact path or filename."
          )
        end
      end
    end

    if match.nil? && child_metadata.nil?
      ancestor_metadata, ancestor_match = nearest_ancestor_match(directory, relative)
      if ancestor_match
        metadata = ancestor_metadata
        match = ancestor_match
        match_kind = "ancestor_exact_path"
        lookup = "ancestor_metadata_only"
        review_finding(
          kind: "text_uses_ancestor_metadata",
          path: relative,
          related_path: ancestor_metadata.relative_path,
          work_id: ancestor_metadata.work_id,
          document_id: ancestor_match.document_id,
          message: "The text is listed by ancestor metadata, but CorpusMetadataStore currently reads metadata.json only from the text's own directory. This is a viewer lookup limitation, not necessarily a corpus-placement defect."
        )
      end
    end

    if metadata_expected
      if direct_metadata&.valid && match.nil?
        review_finding(
          kind: "text_not_listed_by_sibling_metadata",
          path: relative,
          related_path: direct_metadata.relative_path,
          work_id: direct_metadata.work_id,
          message: "A sibling metadata.json exists but does not identify this text by exact path or filename."
        )
      elsif direct_metadata.nil? && child_metadata.nil? && match.nil?
        review_finding(
          kind: "text_without_metadata",
          path: relative,
          message: "No sibling metadata.json, matching ancestor metadata entry, or same-named child metadata was found."
        )
      end
    end

    @matched_document_references << match.key if match

    work_id = metadata&.work_id.to_s
    document_id = match&.document_id.to_s
    work_status = id_status(work_id)
    document_status = id_status(document_id)

    legacy_keys = []
    header_error = ""
    if document_role == "canonical"
      legacy_keys, header_error = legacy_header_keys(absolute)
    else
      @counts["legacy_header_checks_skipped_noncanonical"] += 1
    end
    legacy_header = legacy_keys.any?
    if legacy_header
      @counts["texts_with_legacy_headers"] += 1
      review_finding(
        kind: "legacy_header_remains",
        path: relative,
        work_id: work_id,
        document_id: document_id,
        message: "Leading legacy metadata keys remain: #{legacy_keys.join('; ')}"
      )
    end
    notes = []
    notes << header_error unless header_error.to_s.empty?
    notes << "zero-byte file" if stat.size.zero?

    manifest = @manifest_by_path[relative]
    manifest_presence = manifest ? "present" : (@manifest_loaded ? "absent" : "not_checked")
    manifest_id_status = "not_checked"
    manifest_work_status = "not_checked"

    if manifest
      @manifest_seen_paths << relative
      manifest_id_status = compare_manifest_document_id(
        relative, document_id, manifest["id"], work_id, manifest["work_id"],
        metadata_expected: metadata_expected, source_bucket: source_bucket, document_role: document_role
      )
      manifest_work_status = compare_manifest_work_id(
        relative, work_id, manifest["work_id"], document_id, manifest["id"],
        metadata_expected: metadata_expected
      )
    elsif @manifest_loaded
      manifest_id_status = "not_in_manifest"
      manifest_work_status = "not_in_manifest"
    end

    if document_status != "numeric"
      group_base = metadata&.relative_path.to_s.empty? ? directory : metadata.relative_path
      group_key = [source_bucket, document_role, group_base].join("|")
      row = @fallback_groups[group_key]
      row[:count] += 1
      row[:title] = metadata&.title.to_s
      row[:metadata_path] = metadata&.relative_path.to_s
      row[:work_id] = work_id
      row[:source_bucket] = source_bucket
      row[:document_role] = document_role
      @counts["texts_without_numeric_document_id"] += 1
      @counts["texts_without_numeric_document_id_role_#{document_role}"] += 1
    end
    unless work_status == "numeric"
      @counts["texts_without_numeric_work_id"] += 1
      @counts["texts_without_numeric_work_id_role_#{document_role}"] += 1
    end
    @counts["texts_with_direct_metadata"] += 1 if lookup == "direct_sibling"
    @counts["texts_with_ancestor_metadata_only"] += 1 if lookup == "ancestor_metadata_only"
    @counts["texts_with_child_metadata_layout"] += 1 if lookup.start_with?("metadata_in_same_named_child")
    @counts["raw_texts_without_metadata_expected"] += 1 if !metadata_expected && match.nil?
    @counts["zero_byte_texts"] += 1 if stat.size.zero?

    csv("documents.csv", {
      "path" => relative,
      "size_bytes" => stat.size,
      "source_bucket" => source_bucket,
      "document_role" => document_role,
      "metadata_expected" => metadata_expected,
      "metadata_lookup" => lookup,
      "metadata_path" => metadata&.relative_path.to_s,
      "metadata_match" => match_kind,
      "work_id" => work_id,
      "work_id_status" => work_status,
      "document_id" => document_id,
      "document_id_status" => document_status,
      "legacy_header" => legacy_header,
      "legacy_keys" => legacy_keys.join("; "),
      "manifest_presence" => manifest_presence,
      "manifest_id" => manifest&.fetch("id", "").to_s,
      "manifest_work_id" => manifest&.fetch("work_id", "").to_s,
      "manifest_id_status" => manifest_id_status,
      "manifest_work_id_status" => manifest_work_status,
      "notes" => notes.join("; ")
    })
  rescue *READ_ERRORS => error
    record_read_error("audit_text", absolute, error)
  end

  def match_document(metadata, relative, filename)
    return [nil, ""] unless metadata&.valid

    exact = Array(metadata.by_path[relative])
    return [exact.first, "exact_path"] if exact.length == 1
    if exact.length > 1
      review_finding(
        kind: "ambiguous_metadata_path_match",
        path: relative,
        related_path: metadata.relative_path,
        work_id: metadata.work_id,
        message: "More than one metadata document entry resolves to this path."
      )
      return [nil, "ambiguous_exact_path"]
    end

    file_matches = Array(metadata.by_file[filename])
    return [file_matches.first, "filename"] if file_matches.length == 1
    if file_matches.length > 1
      review_finding(
        kind: "ambiguous_metadata_filename_match",
        path: relative,
        related_path: metadata.relative_path,
        work_id: metadata.work_id,
        message: "More than one metadata document entry uses this filename."
      )
      return [nil, "ambiguous_filename"]
    end

    [nil, ""]
  end

  def nearest_ancestor_match(directory, relative)
    current = Pathname(directory.empty? ? "." : directory)
    loop do
      parent = current.parent
      break if parent.to_s == current.to_s || parent.to_s == "."

      key = normalize_relative(parent.to_s)
      metadata = @metadata_by_directory[key]
      if metadata&.valid
        matches = Array(metadata.by_path[relative])
        return [metadata, matches.first] if matches.length == 1
      end
      current = parent
    end
    [nil, nil]
  end

  def legacy_header_keys(path)
    raw = File.open(path, "rb") { |file| file.read(@options[:header_bytes]) }.to_s
    text = raw.force_encoding(Encoding::UTF_8)
    return [[], "invalid UTF-8 in header sample"] unless text.valid_encoding?

    keys = []
    text.each_line.with_index do |line, index|
      line = line.delete_prefix("\uFEFF")
      stripped = line.chomp
      if (match = HEADER_PATTERN.match(stripped))
        keys << match[1].strip
      elsif stripped.start_with?("#") || stripped.strip.empty?
        next
      else
        break
      end
    end
    [keys.uniq, ""]
  rescue *READ_ERRORS => error
    record_read_error("legacy_header", path, error)
    [[], "#{error.class}: #{error.message}"]
  end

  # ------------------------- manifest comparison --------------------------

  def compare_manifest_document_id(path, metadata_id, manifest_id, metadata_work_id, manifest_work_id,
      metadata_expected:, source_bucket:, document_role:)
    expected_fallback = Digest::SHA256.hexdigest(path)[0, 24]
    status = if !metadata_expected && manifest_id == expected_fallback
      "unmanaged_raw_path_hash"
    elsif metadata_id.match?(NUMERIC_ID_PATTERN)
      if manifest_id == metadata_id
        "matches_metadata"
      elsif manifest_id == expected_fallback
        "path_hash_despite_numeric_metadata"
      else
        "mismatch"
      end
    elsif manifest_id == expected_fallback
      "confirmed_path_hash_fallback"
    elsif manifest_id.empty?
      "manifest_id_missing"
    else
      "manifest_has_non_metadata_id"
    end

    case status
    when "path_hash_despite_numeric_metadata", "mismatch", "manifest_id_missing"
      review_manifest_finding(
        kind: status,
        path: path,
        metadata_document_id: metadata_id,
        manifest_id: manifest_id,
        metadata_work_id: metadata_work_id,
        manifest_work_id: manifest_work_id,
        message: manifest_document_message(status)
      )
    when "confirmed_path_hash_fallback"
      @counts["manifest_confirmed_fallback_ids"] += 1
    when "unmanaged_raw_path_hash"
      @counts["manifest_unmanaged_raw_fallback_ids"] += 1
      @counts["manifest_unmanaged_#{source_bucket}_#{document_role}_fallback_ids"] += 1
    end
    @counts["manifest_path_hash_despite_numeric_metadata"] += 1 if status == "path_hash_despite_numeric_metadata"
    status
  end

  def compare_manifest_work_id(path, metadata_id, manifest_id, metadata_document_id, manifest_document_id, metadata_expected:)
    return manifest_id.empty? ? "unmanaged_source_no_work_id" : "unmanaged_source_manifest_work_id" unless metadata_expected

    status = if metadata_id.empty?
      manifest_id.empty? ? "both_missing" : "manifest_only"
    elsif manifest_id == metadata_id
      "matches_metadata"
    elsif manifest_id.empty?
      "manifest_missing_work_id"
    else
      "mismatch"
    end

    if %w[manifest_missing_work_id mismatch].include?(status)
      review_manifest_finding(
        kind: "work_id_#{status}",
        path: path,
        metadata_document_id: metadata_document_id,
        manifest_id: manifest_document_id,
        metadata_work_id: metadata_id,
        manifest_work_id: manifest_id,
        message: "Manifest work_id does not agree with the sibling/ancestor metadata used by the audit."
      )
    end
    status
  end

  def manifest_document_message(status)
    case status
    when "path_hash_despite_numeric_metadata"
      "metadata.json has a numeric document_id, but the manifest still contains the path hash. This normally means stale manifest data or failed metadata lookup during manifest construction."
    when "mismatch"
      "Manifest document ID differs from metadata.json and is not the expected path hash."
    when "manifest_id_missing"
      "Manifest row has no document ID."
    else
      status
    end
  end

  def finish_manifest_audit
    stale_paths = @manifest_by_path.keys.reject { |path| @manifest_seen_paths.include?(path) }
    stale_paths.sort.each do |path|
      manifest = @manifest_by_path.fetch(path)
      review_manifest_finding(
        kind: "manifest_path_missing_from_corpus_scan",
        path: path,
        metadata_document_id: "",
        manifest_id: manifest["id"],
        metadata_work_id: "",
        manifest_work_id: manifest["work_id"],
        message: "The manifest lists a path not found during this corpus scan."
      )
    end
    @counts["manifest_paths_missing_from_scan"] = stale_paths.length
  end

  # ----------------------- document-reference finish ----------------------

  def finish_document_reference_audit
    @document_references.each_value do |reference|
      next unless reference.exists
      next if @matched_document_references.include?(reference.key)

      review_finding(
        kind: "existing_metadata_document_not_matched_to_scanned_text",
        path: reference.metadata_path,
        related_path: reference.resolved_path,
        work_id: reference.work_id,
        document_id: reference.document_id,
        message: "The metadata entry resolves to an existing file, but the audit did not match that file back to this entry."
      )
    end
  end

  # ----------------------------- identifiers ------------------------------

  def register_id(kind, id, occurrence)
    return if id.to_s.empty?

    first = kind == :work ? @work_id_first : @document_id_first
    duplicates = kind == :work ? @work_id_duplicates : @document_id_duplicates
    key = id.to_s
    if first.key?(key)
      duplicates[key] << first[key] if duplicates[key].empty?
      duplicates[key] << occurrence
    else
      first[key] = occurrence
    end
  end

  def write_duplicate_reports
    write_duplicate_csv("duplicate_work_ids.csv", "work_id", @work_id_duplicates)
    write_duplicate_csv("duplicate_document_ids.csv", "document_id", @document_id_duplicates)

    @counts["duplicate_work_ids"] = @work_id_duplicates.length
    @counts["duplicate_document_ids"] = @document_id_duplicates.length
    @work_id_duplicates.each do |id, occurrences|
      confirmed_error(
        kind: "duplicate_work_id",
        path: occurrences.first,
        work_id: id,
        message: "work_id #{id} occurs in #{occurrences.length} metadata locations. See duplicate_work_ids.csv."
      )
    end
    @document_id_duplicates.each do |id, occurrences|
      confirmed_error(
        kind: "duplicate_document_id",
        path: occurrences.first,
        document_id: id,
        message: "document_id #{id} occurs in #{occurrences.length} metadata document entries. See duplicate_document_ids.csv."
      )
    end
  end

  def write_duplicate_csv(name, id_header, duplicates)
    CSV.open(@output_root.join(name), "w", encoding: "UTF-8", write_headers: true,
      headers: [id_header, "occurrence_count", "occurrences"]) do |output|
      duplicates.sort_by { |id, _| numeric_sort_key(id) }.each do |id, occurrences|
        output << {
          id_header => id,
          "occurrence_count" => occurrences.length,
          "occurrences" => occurrences.uniq.join(" | ")
        }
      end
    end
  end

  def id_status(value)
    value = value.to_s
    return "missing" if value.empty?
    return "numeric" if value.match?(NUMERIC_ID_PATTERN)
    return "path_hash_shape" if value.match?(FALLBACK_ID_PATTERN)

    "non_numeric"
  end

  # -------------------------------- atlas ---------------------------------

  def audit_atlas
    @counts["atlas_audit_run"] = 1
    log "phase 4: auditing atlas source state"
    periodisation_path = @viewer_root.join("content", "atlas", "periodisation.json")
    if periodisation_path.file?
      begin
        data = JSON.parse(periodisation_path.read(encoding: "UTF-8"))
        western = Array(data["macro_regions"]).select do |region|
          region.is_a?(Hash) && (region["id"].to_s == "西域" || region["label"].to_s.include?("Western Regions"))
        end
        western.each do |region|
          atlas_finding(
            severity: "review",
            kind: "unwanted_western_regions_macro_region",
            path: relative_to_viewer(periodisation_path),
            entry_id: region["id"],
            name: region["label"],
            period_ids: Array(region["period_ids"]),
            message: "The empty 西域 / Western Regions atlas macro-region remains in periodisation.json."
          )
        end
        @counts["atlas_western_regions_entries"] = western.length
        excluded = Array(data["excluded_corpus_roots"]).map(&:to_s)
        if excluded.include?("西域漢文")
          atlas_finding(
            severity: "info",
            kind: "western_regions_corpus_root_excluded",
            path: relative_to_viewer(periodisation_path),
            message: "西域漢文 remains a real corpus root but is explicitly excluded from Atlas publication."
          )
          @counts["atlas_western_regions_root_excluded"] = 1
        elsif western.empty?
          atlas_finding(
            severity: "review",
            kind: "western_regions_root_not_excluded",
            path: relative_to_viewer(periodisation_path),
            message: "The 西域 macro-region is absent, but 西域漢文 is not listed in excluded_corpus_roots. A rebuild could rediscover it through corpus data."
          )
        end
      rescue JSON::ParserError, SystemCallError => error
        atlas_finding(
          severity: "error",
          kind: "invalid_periodisation_json",
          path: relative_to_viewer(periodisation_path),
          message: "#{error.class}: #{error.message}"
        )
      end
    else
      atlas_finding(
        severity: "review",
        kind: "periodisation_json_missing",
        path: relative_to_viewer(periodisation_path),
        message: "Atlas periodisation.json was not found."
      )
    end

    audit_atlas_entries
    audit_atlas_source_references
    audit_atlas_ordering_code
    log "atlas audit complete"
  end

  def audit_atlas_entries
    entry_glob = @viewer_root.join("content", "atlas", "entries", "*", "metadata.json").to_s
    names = Hash.new { |hash, key| hash[key] = [] }
    multi_period = []
    entry_count = 0

    Dir.glob(entry_glob).sort.each do |path_string|
      path = Pathname(path_string)
      begin
        data = JSON.parse(path.read(encoding: "UTF-8"))
        entry_count += 1
        entry_id = data["id"].to_s
        name = first_present(data.dig("name", "hanzi"), data.dig("name", "display"), entry_id)
        period_ids = Array(data.dig("atlas", "period_ids")).map(&:to_s).reject(&:empty?)
        names[name] << [entry_id, relative_to_viewer(path)] unless name.empty?
        if period_ids.length > 1
          multi_period << [entry_id, name, period_ids, relative_to_viewer(path)]
          csv("atlas_multi_period_entries.csv", {
            "entry_id" => entry_id,
            "name" => name,
            "period_count" => period_ids.length,
            "period_ids" => period_ids.join("; "),
            "metadata_path" => relative_to_viewer(path)
          })
        end
      rescue JSON::ParserError, SystemCallError => error
        atlas_finding(
          severity: "error",
          kind: "invalid_atlas_entry_metadata",
          path: relative_to_viewer(path),
          message: "#{error.class}: #{error.message}"
        )
      end
    end

    names.each do |name, rows|
      next unless rows.length > 1

      csv("atlas_same_name_entries.csv", {
        "name" => name,
        "entry_count" => rows.length,
        "entry_ids" => rows.map(&:first).join("; "),
        "metadata_paths" => rows.map(&:last).join("; ")
      })
    end

    @counts["atlas_entries"] = entry_count
    @counts["atlas_multi_period_entries"] = multi_period.length
    @counts["atlas_reused_names"] = names.count { |_name, rows| rows.length > 1 }

    atlas_finding(
      severity: "info",
      kind: "cross_period_continuity_summary",
      path: "content/atlas/entries",
      message: "#{multi_period.length} atlas entries already span more than one period: #{multi_period.map { |row| "#{row[1]} (#{row[2].join('/')})" }.join('; ')}"
    )
  end

  def audit_atlas_source_references
    rules_path = @viewer_root.join("script", "atlas_node_type_rules.json")
    unless rules_path.file?
      atlas_finding(
        severity: "review",
        kind: "atlas_node_type_rules_missing",
        path: relative_to_viewer(rules_path),
        message: "The Atlas rectification rules were not found."
      )
      return
    end

    begin
      rules = JSON.parse(rules_path.read(encoding: "UTF-8"))
      western = Array(rules["macro_regions"]).select do |region|
        region.is_a?(Hash) && (region["id"].to_s == "西域" || region["label"].to_s.include?("Western Regions"))
      end
      western.each do |region|
        atlas_finding(
          severity: "review",
          kind: "western_regions_rectification_rule",
          path: relative_to_viewer(rules_path),
          entry_id: region["id"],
          name: region["label"],
          message: "The rectification rules would recreate the unwanted 西域 macro-region."
        )
      end

      excluded = Array(rules["excluded_corpus_roots"]).map(&:to_s)
      unless excluded.include?("西域漢文")
        atlas_finding(
          severity: "review",
          kind: "western_regions_missing_from_rule_exclusions",
          path: relative_to_viewer(rules_path),
          message: "atlas_node_type_rules.json should exclude 西域漢文 so rerunning rectification cannot republish it."
        )
      end
    rescue JSON::ParserError, SystemCallError => error
      atlas_finding(
        severity: "error",
        kind: "invalid_atlas_node_type_rules",
        path: relative_to_viewer(rules_path),
        message: "#{error.class}: #{error.message}"
      )
    end

    rectifier = @viewer_root.join("script", "rectify_atlas_node_types.rb")
    if rectifier.file?
      text = rectifier.read(encoding: "UTF-8")
      unless text.include?('"excluded_corpus_roots"')
        atlas_finding(
          severity: "review",
          kind: "rectifier_drops_excluded_corpus_roots",
          path: relative_to_viewer(rectifier),
          message: "rewrite_periodisation! does not appear to preserve excluded_corpus_roots from the rules file."
        )
      end
    end
  end

  def audit_atlas_ordering_code
    builder = @viewer_root.join("app", "services", "atlas", "catalogue_builder.rb")
    unless builder.file?
      atlas_finding(
        severity: "review",
        kind: "catalogue_builder_missing",
        path: relative_to_viewer(builder),
        message: "Cannot inspect atlas ordering because catalogue_builder.rb is absent."
      )
      return
    end

    lines = builder.readlines(encoding: "UTF-8")
    helper_start = lines.index { |line| line.match?(/^\s*def\s+sort_entry_ids\b/) }
    helper_context = helper_start ? lines[helper_start, 20].to_a.join : ""
    helper_uses_work_count = helper_context.match?(/work_count/) &&
      helper_context.match?(/-\s*work_count/) && helper_context.match?(/title/)
    navigation_calls = []
    lines.each_with_index do |line, index|
      next unless line.include?("sort_entry_ids")
      next if line.match?(/^\s*def\s+sort_entry_ids\b/)

      context = lines[[index - 2, 0].max, 5].to_a.join
      navigation_calls << index + 1 if context.include?("entry_ids") || context.include?("direct_entry_ids")
    end

    if helper_uses_work_count && navigation_calls.any?
      atlas_finding(
        severity: "info",
        kind: "atlas_ordering_work_count_then_title",
        path: relative_to_viewer(builder),
        line: helper_start + 1,
        message: "Atlas navigation calls sort_entry_ids, whose key is work count descending followed by title. Navigation call lines: #{navigation_calls.join(', ')}."
      )
    else
      title_only_lines = []
      lines.each_with_index do |line, index|
        title_only_lines << index + 1 if line.include?("sort_by") && line.match?(/entry_title\s*\(/)
      end
      atlas_finding(
        severity: "review",
        kind: "atlas_ordering_requires_review",
        path: relative_to_viewer(builder),
        line: (helper_start ? helper_start + 1 : title_only_lines.first),
        message: "Could not confirm that Atlas navigation is ordered by represented work count descending and then title. sort_entry_ids navigation calls=#{navigation_calls.length}; title-only candidates=#{title_only_lines.join(', ')}."
      )
    end
  rescue Encoding::InvalidByteSequenceError, SystemCallError => error
    atlas_finding(
      severity: "error",
      kind: "catalogue_builder_unreadable",
      path: relative_to_viewer(builder),
      message: "#{error.class}: #{error.message}"
    )
  end

  # -------------------------------- Shang ---------------------------------

  def audit_shang
    @counts["shang_audit_run"] = 1
    log "phase 5: checking whether the Shang object-centred layout appears applied"

    unless complete_shang_scan?
      @counts["shang_assessment_partial"] = 1
      shang_finding(
        "info", "shang_assessment_skipped_partial_scan", "中國漢文/clean/商殷朝", 0,
        "The current scope/filter/max-files settings do not cover the complete Shang clean tree. No separate rescan was performed. Run a full audit or --scope 中國漢文/clean/商殷朝 without --max-files."
      )
      return
    end

    config_path = @viewer_root.join("config", "corpus_metadata", "shang_inscription_regionalisation.yml")
    unless config_path.file?
      shang_finding("review", "config_missing", relative_to_viewer(config_path), 0, "Shang regionalisation config was not found.")
      return
    end

    config = YAML.safe_load(config_path.read(encoding: "UTF-8"), aliases: true) || {}
    shang_base = "中國漢文/clean/商殷朝"
    unless @directories_seen.include?(shang_base)
      shang_finding("review", "shang_root_missing", shang_base, 0, "Expected Shang root was not encountered in the scan.")
      return
    end

    Array(config["folder_skeleton"]).each do |parts|
      relative = join_relative(shang_base, Array(parts).join("/"))
      next if @directories_seen.include?(relative)

      shang_finding("review", "missing_target_skeleton_folder", relative, 0, "Configured target folder is absent.")
    end

    target_metadata = @shang_scan["target_metadata"]
    target_texts = @shang_scan["target_texts"]
    legacy_texts = @shang_scan["legacy_texts"]
    legacy_metadata = @shang_scan["legacy_metadata"]
    huadong_zero_objects = @shang_scan["huadong_zero_object_paths"]
    huadong_zero_aliases = @shang_scan["huadong_zero_source_alias_files"]
    h3_metadata = @shang_scan["h3_metadata"]
    h3_texts = @shang_scan["h3_texts"]

    shang_finding("info", "target_object_layout", shang_base, target_metadata,
      "Object-centred target roots contain #{target_metadata} metadata files and #{target_texts} text files.")

    severity = legacy_texts.positive? || legacy_metadata.positive? ? "review" : "info"
    shang_finding(severity, "legacy_source_roots", shang_base, legacy_texts,
      "Legacy source roots contain #{legacy_texts} text files and #{legacy_metadata} metadata files.")

    if huadong_zero_objects.positive?
      shang_finding("error", "fictional_huadong_zero_object_path", shang_base, huadong_zero_objects,
        "One or more paths contain a directory component exactly named 花東0. Source filenames such as 花東0.9_Schwartz.txt are deliberately not counted here.")
    end

    shang_finding("info", "huadong_zero_source_aliases", shang_base, huadong_zero_aliases,
      "#{huadong_zero_aliases} source/translation filenames retain labels such as 花東0.9. These are source locators inside canonical H3 objects, not fictional object folders.")

    h3 = "#{shang_base}/商/甲骨文/殷墟/花園莊東地/H3"
    shang_finding(@directories_seen.include?(h3) ? "info" : "review", "huayuanzhuang_h3", h3, h3_metadata,
      "H3 target contains #{h3_metadata} metadata files and #{h3_texts} text files.")

    appears_applied = target_metadata.positive? && target_texts.positive? && legacy_texts.zero? && legacy_metadata.zero? && huadong_zero_objects.zero?
    @counts["shang_appears_applied"] = appears_applied ? 1 : 0
    @counts["shang_target_metadata"] = target_metadata
    @counts["shang_target_texts"] = target_texts
    @counts["shang_legacy_texts"] = legacy_texts
    @counts["shang_legacy_metadata"] = legacy_metadata
    @counts["shang_huadong_zero_object_paths"] = huadong_zero_objects
    @counts["shang_huadong_zero_source_alias_files"] = huadong_zero_aliases
    shang_finding("info", "apply_assessment", shang_base, appears_applied ? 1 : 0,
      appears_applied ? "The physical tree is consistent with an applied object-centred migration." : "The audit cannot confidently infer a completed apply from the physical tree alone; review the preceding Shang findings.")
    log "Shang audit complete"
  rescue Psych::SyntaxError, SystemCallError => error
    shang_finding("error", "shang_audit_error", relative_to_viewer(config_path), 0, "#{error.class}: #{error.message}")
  end

  # ------------------------------ reports ---------------------------------

  def write_fallback_groups
    CSV.open(@output_root.join("documents_without_numeric_ids_by_group.csv"), "w", encoding: "UTF-8",
      write_headers: true, headers: %w[count source_bucket document_role work_id title metadata_path group_key]) do |output|
      @fallback_groups.sort_by { |_key, row| [-row[:count], row[:source_bucket], row[:document_role], row[:title], row[:metadata_path]] }.each do |key, row|
        output << {
          "count" => row[:count],
          "source_bucket" => row[:source_bucket],
          "document_role" => row[:document_role],
          "work_id" => row[:work_id],
          "title" => row[:title],
          "metadata_path" => row[:metadata_path],
          "group_key" => key
        }
      end
    end
  end

  def write_summaries(partial: false)
    finished = Time.now.utc
    summary = {
      "version" => VERSION,
      "partial" => partial,
      "started_at" => @started_at.iso8601,
      "finished_at" => finished.iso8601,
      "elapsed_seconds" => (finished - @started_at).round(3),
      "viewer_root" => @viewer_root.to_s,
      "corpus_root" => @corpus_root.to_s,
      "scan" => {
        "root" => @scan_root.to_s,
        "scope" => @scope,
        "clean_only" => @options[:clean_only],
        "raw_only" => @options[:raw_only],
        "max_files" => @options[:max_files],
        "partial" => partial_scan?
      },
      "output_root" => @output_root.to_s,
      "phase_timings_seconds" => @phase_timings,
      "manifest" => {
        "requested" => @options[:use_manifest],
        "path" => @manifest_path.to_s,
        "loaded" => !!@manifest_loaded,
        "version" => @manifest_version,
        "generated_at" => @manifest_generated_at
      },
      "confirmed_errors" => @confirmed_errors,
      "review_findings" => @review_findings,
      "counts" => @counts.sort.to_h,
      "fatal_error" => @fatal_error.to_s
    }
    @output_root.join("summary.json").write(JSON.pretty_generate(summary) + "\n", encoding: "UTF-8")
    @output_root.join("summary.txt").write(human_summary(summary), encoding: "UTF-8")
    @output_root.join("README.txt").write(output_readme, encoding: "UTF-8")
  rescue SystemCallError => error
    warn "[project-state-audit] could not write summary: #{error.class}: #{error.message}"
  end

  def human_summary(summary)
    counts = summary.fetch("counts")
    scan = summary.fetch("scan")
    <<~TEXT
      Fanya Hanwen Corpus project-state audit
      ========================================

      Status: #{summary['partial'] ? 'PARTIAL / SCOPED TEST' : 'COMPLETE'}
      Started: #{summary['started_at']}
      Finished: #{summary['finished_at']}
      Elapsed: #{summary['elapsed_seconds']} seconds
      Scope: #{scan['scope'].to_s.empty? ? '(full corpus)' : scan['scope']}
      Filters: clean_only=#{scan['clean_only']}, raw_only=#{scan['raw_only']}, max_files=#{scan['max_files']}

      Corpus
      ------
      Text files: #{counts.fetch('txt_files', 0)}
        canonical clean texts: #{counts.fetch('texts_role_canonical', 0)}
        translations: #{counts.fetch('texts_role_translation', 0)}
        annotations: #{counts.fetch('texts_role_annotation', 0)}
        variants: #{counts.fetch('texts_role_variant', 0)}
        raw source texts: #{counts.fetch('texts_role_raw', 0)}
        other texts: #{counts.fetch('texts_role_other', 0)}
      metadata.json files: #{counts.fetch('metadata_files', 0)}
      Valid metadata: #{counts.fetch('valid_metadata', 0)}
      Invalid metadata: #{counts.fetch('invalid_metadata', 0)}
      Texts with direct sibling metadata: #{counts.fetch('texts_with_direct_metadata', 0)}
      Texts using ancestor metadata only: #{counts.fetch('texts_with_ancestor_metadata_only', 0)}
      Texts in the same-named-child layout: #{counts.fetch('texts_with_child_metadata_layout', 0)}
      Raw texts for which metadata was not expected: #{counts.fetch('raw_texts_without_metadata_expected', 0)}
      Texts without numeric work IDs: #{counts.fetch('texts_without_numeric_work_id', 0)}
        canonical: #{counts.fetch('texts_without_numeric_work_id_role_canonical', 0)}
        raw: #{counts.fetch('texts_without_numeric_work_id_role_raw', 0)}
      Texts without numeric document IDs: #{counts.fetch('texts_without_numeric_document_id', 0)}
        canonical: #{counts.fetch('texts_without_numeric_document_id_role_canonical', 0)}
        raw: #{counts.fetch('texts_without_numeric_document_id_role_raw', 0)}
      Duplicate work IDs: #{counts.fetch('duplicate_work_ids', 0)}
      Duplicate document IDs: #{counts.fetch('duplicate_document_ids', 0)}
      Legacy headers remaining in canonical texts: #{counts.fetch('texts_with_legacy_headers', 0)}
      Backup files: #{counts.fetch('backup_files', 0)} (#{counts.fetch('backup_bytes', 0)} bytes)

      Manifest
      --------
      Loaded: #{summary.dig('manifest', 'loaded')}
      Documents: #{counts.fetch('manifest_documents', 0)}
      Unmanaged raw path-hash IDs: #{counts.fetch('manifest_unmanaged_raw_fallback_ids', 0)}
      Metadata-backed path-hash fallback IDs: #{counts.fetch('manifest_confirmed_fallback_ids', 0)}
      Path hashes despite numeric metadata: #{counts.fetch('manifest_path_hash_despite_numeric_metadata', 0)}
      Manifest paths absent from corpus scan: #{counts.fetch('manifest_paths_missing_from_scan', 0)}

      Atlas
      -----
      Audit run: #{counts.fetch('atlas_audit_run', 0) == 1}
      Entries: #{counts.fetch('atlas_entries', 0)}
      Multi-period entries already present: #{counts.fetch('atlas_multi_period_entries', 0)}
      Western Regions macro-region entries: #{counts.fetch('atlas_western_regions_entries', 0)}
      西域漢文 explicitly excluded: #{counts.fetch('atlas_western_regions_root_excluded', 0) == 1}

      Shang
      -----
      Audit run: #{counts.fetch('shang_audit_run', 0) == 1}
      Assessment partial/skipped: #{counts.fetch('shang_assessment_partial', 0) == 1}
      Appears applied: #{counts.fetch('shang_appears_applied', 0) == 1}
      Target metadata files: #{counts.fetch('shang_target_metadata', 0)}
      Target text files: #{counts.fetch('shang_target_texts', 0)}
      Remaining legacy-root text files: #{counts.fetch('shang_legacy_texts', 0)}
      Exact 花東0 object-path components: #{counts.fetch('shang_huadong_zero_object_paths', 0)}
      花東0.* source-locator filenames: #{counts.fetch('shang_huadong_zero_source_alias_files', 0)}

      Findings
      --------
      Confirmed structural errors: #{summary['confirmed_errors']}
      Items requiring review: #{summary['review_findings']}

      Phase timings are recorded in summary.json under phase_timings_seconds.
      Read the CSV files for exact paths.
    TEXT
  end

  def output_readme
    <<~TEXT
      This folder was produced by script/project_state_audit.rb.

      The script is read-only. It did not modify the corpus, metadata, search
      manifest, atlas, routes, database, or viewer source.

      Start with:
        1. summary.txt
        2. structural_findings.csv
        3. manifest_findings.csv
        4. documents_without_numeric_ids_by_group.csv
        5. atlas_findings.csv
        6. shang_findings.csv

      Important distinctions:
        * confirmed_path_hash_fallback means metadata itself supplied no numeric
          document ID to the audit.
        * path_hash_despite_numeric_metadata means the corpus metadata has an ID,
          but the manifest does not use it. Rebuilding the manifest or fixing the
          viewer's metadata lookup may solve this without changing corpus IDs.
        * ancestor_metadata_only means a metadata file lists the text, but it is
          not in the directory CorpusMetadataStore currently checks.
        * metadata_in_same_named_child means the text is one level too high, for
          example clean/〇.txt beside clean/〇/metadata.json. The desired form is
          clean/〇/〇.txt beside clean/〇/metadata.json.

      No report is an instruction to delete or move files automatically. Review
      exact rows before producing any apply script.
    TEXT
  end

  # ----------------------------- findings ---------------------------------

  def confirmed_error(kind:, path:, message:, related_path: "", work_id: "", document_id: "")
    @confirmed_errors += 1
    finding(
      severity: "error",
      kind: kind,
      path: path,
      related_path: related_path,
      work_id: work_id,
      document_id: document_id,
      message: message
    )
  end

  def review_finding(kind:, path:, message:, related_path: "", work_id: "", document_id: "")
    @review_findings += 1
    finding(
      severity: "review",
      kind: kind,
      path: path,
      related_path: related_path,
      work_id: work_id,
      document_id: document_id,
      message: message
    )
  end

  def finding(severity:, kind:, path:, message:, related_path: "", work_id: "", document_id: "")
    csv("structural_findings.csv", {
      "severity" => severity,
      "kind" => kind,
      "path" => path,
      "related_path" => related_path,
      "work_id" => work_id,
      "document_id" => document_id,
      "message" => message
    })
  end

  def review_manifest_finding(kind:, path:, metadata_document_id:, manifest_id:, metadata_work_id:, manifest_work_id:, message:)
    @review_findings += 1
    csv("manifest_findings.csv", {
      "severity" => "review",
      "kind" => kind,
      "path" => path,
      "metadata_document_id" => metadata_document_id,
      "manifest_id" => manifest_id,
      "metadata_work_id" => metadata_work_id,
      "manifest_work_id" => manifest_work_id,
      "message" => message
    })
  end

  def atlas_finding(severity:, kind:, path:, message:, line: "", entry_id: "", name: "", period_ids: [])
    @confirmed_errors += 1 if severity == "error"
    @review_findings += 1 if severity == "review"
    csv("atlas_findings.csv", {
      "severity" => severity,
      "kind" => kind,
      "path" => path,
      "line" => line,
      "entry_id" => entry_id,
      "name" => name,
      "period_ids" => Array(period_ids).join("; "),
      "message" => message
    })
  end

  def shang_finding(severity, kind, path, count, message)
    @confirmed_errors += 1 if severity == "error"
    @review_findings += 1 if severity == "review"
    csv("shang_findings.csv", {
      "severity" => severity,
      "kind" => kind,
      "path" => path,
      "count" => count,
      "message" => message
    })
  end

  def record_enumeration_error(operation, path, error)
    @enumeration_errors << [operation, path.to_s, error.class.name, error.message]
    @counts["enumeration_errors"] += 1
    csv("enumeration_errors.csv", {
      "operation" => operation,
      "path" => display_path(path),
      "error_class" => error.class.name,
      "message" => error.message
    })
  end

  def record_read_error(operation, path, error)
    @read_errors << [operation, path.to_s, error.class.name, error.message]
    @counts["read_errors"] += 1
    csv("read_errors.csv", {
      "operation" => operation,
      "path" => display_path(path),
      "error_class" => error.class.name,
      "message" => error.message
    })
  end

  # ------------------------------ helpers ---------------------------------

  def normalize_relative(value)
    utf8_string(value).tr("\\", "/").sub(%r{\A\./}, "").sub(%r{\A/+}, "").sub(%r{/+\z}, "")
  end

  def normalize_cli_path(value)
    normalize_relative(value)
  end

  def utf8_string(value)
    text = value.to_s.dup
    text.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8
    text.valid_encoding? ? text : text.scrub("\uFFFD")
  end

  def safely_under_root?(path, root)
    relative = Pathname(path).relative_path_from(Pathname(root)).to_s
    relative != ".." && !relative.start_with?("../")
  rescue ArgumentError
    false
  end

  def join_relative(*parts)
    normalize_relative(parts.map(&:to_s).reject(&:empty?).join("/"))
  end

  def relative_to_corpus(path)
    Pathname(path).relative_path_from(@corpus_root).to_s.tr("\\", "/")
  rescue ArgumentError
    path.to_s.tr("\\", "/")
  end

  def relative_to_viewer(path)
    Pathname(path).relative_path_from(@viewer_root).to_s.tr("\\", "/")
  rescue ArgumentError
    path.to_s.tr("\\", "/")
  end

  def display_path(path)
    pathname = Pathname(path)
    return relative_to_corpus(pathname) if pathname.to_s.start_with?(@corpus_root.to_s)
    return relative_to_viewer(pathname) if pathname.to_s.start_with?(@viewer_root.to_s)

    pathname.to_s.tr("\\", "/")
  end

  def first_present(*values)
    values.map(&:to_s).find { |value| !value.strip.empty? }.to_s
  end

  def numeric_sort_key(value)
    value.to_s.match?(NUMERIC_ID_PATTERN) ? [0, value.to_i] : [1, value.to_s]
  end
end

ProjectStateAudit.new(ARGV).run
