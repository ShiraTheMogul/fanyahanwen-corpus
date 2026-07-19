#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "json"
require "digest"
require "fileutils"
require "find"
require "open3"
require "optparse"
require "pathname"
require "time"

class FallbackIdRepairInputExtractor
  VERSION = 1
  PROGRESS_INTERVAL = 1_000
  SMALL_GROUP_COPY_LIMIT = 100
  LARGE_GROUP_SAMPLE_COUNT = 7

  def initialize(argv)
    @options = {
      viewer_root: Pathname.pwd,
      corpus_root: nil,
      id_registry: nil,
      output_root: nil,
      fallback_documents: nil,
      fallback_works: nil
    }
    parse_options!(argv)
  end

  def run
    resolve_paths!
    validate_inputs!
    prepare_output!

    log "loading fallback-document report"
    fallback_documents = load_csv(@fallback_documents_path)
    fallback_works = load_csv(@fallback_works_path)

    docs_by_folder = fallback_documents.group_by { |row| normalize_rel(row.fetch("folder_path")) }
    expected_paths = fallback_documents.to_h { |row| [normalize_rel(row.fetch("path")), row] }

    log "targets=#{fallback_works.length}, fallback documents=#{fallback_documents.length}"

    copy_input_reports
    registry_summary = extract_registry_rows(fallback_works)

    total_files = 0
    total_bytes = 0
    total_samples = 0
    group_summaries = []
    global_inventory_rows = []
    global_sample_rows = []
    missing_expected_paths = []
    scan_issues = []

    fallback_works.each_with_index do |work_row, index|
      folder_rel = normalize_rel(work_row.fetch("folder_path"))
      group_key = group_key_for(work_row, index)
      group_dir = @package_dir.join("groups", group_key)
      FileUtils.mkdir_p(group_dir)

      log "group #{index + 1}/#{fallback_works.length}: #{group_key} #{folder_rel}"
      folder_abs = @corpus_root.join(folder_rel)
      expected_rows = docs_by_folder.fetch(folder_rel, [])

      inventory_rows, issues = inventory_folder(folder_abs, folder_rel, expected_paths)
      scan_issues.concat(issues.map { |issue| issue.merge("group_key" => group_key) })

      write_csv(group_dir.join("inventory.csv"), inventory_headers, inventory_rows)
      global_inventory_rows.concat(inventory_rows.map { |row| row.merge("group_key" => group_key) })

      expected_in_group = expected_rows.map { |row| normalize_rel(row.fetch("path")) }
      found_paths = inventory_rows.map { |row| row.fetch("corpus_relative_path") }.to_h { |path| [path, true] }
      expected_in_group.each do |path|
        next if found_paths[path]
        missing_expected_paths << {
          "group_key" => group_key,
          "folder_path" => folder_rel,
          "expected_path" => path,
          "document_id" => expected_paths.fetch(path).fetch("document_id", ""),
          "work_id" => expected_paths.fetch(path).fetch("work_id", "")
        }
      end

      ancestor_rows = copy_metadata_chain(folder_abs, folder_rel, group_dir)
      write_csv(group_dir.join("metadata_chain.csv"), %w[level corpus_relative_path copied_as exists sha256 size_bytes], ancestor_rows)

      sample_rows = copy_samples(group_key, folder_abs, folder_rel, inventory_rows, group_dir)
      write_csv(group_dir.join("sample_map.csv"), sample_headers, sample_rows)
      global_sample_rows.concat(sample_rows.map { |row| row.merge("group_key" => group_key) })

      fallback_rows_for_group = expected_rows.map do |row|
        {
          "doc_id" => row["doc_id"],
          "document_id" => row["document_id"],
          "work_id" => row["work_id"],
          "work" => row["work"],
          "title" => row["title"],
          "folder_path" => normalize_rel(row["folder_path"]),
          "path" => normalize_rel(row["path"]),
          "reason" => row["reason"]
        }
      end
      write_csv(group_dir.join("fallback_rows.csv"), fallback_document_headers, fallback_rows_for_group)

      txt_rows = inventory_rows.select { |row| row["extension"].downcase == ".txt" }
      matched_fallback_count = inventory_rows.count { |row| row["expected_fallback"] == "true" }
      unexpected_txt_count = txt_rows.count { |row| row["expected_fallback"] != "true" }

      summary = {
        "group_key" => group_key,
        "work_id" => work_row["work_id"],
        "work" => work_row["work"],
        "title" => work_row["title"],
        "folder_path" => folder_rel,
        "folder_exists" => folder_abs.directory?,
        "expected_fallback_documents" => expected_rows.length,
        "inventory_files" => inventory_rows.length,
        "inventory_txt_files" => txt_rows.length,
        "matched_fallback_documents" => matched_fallback_count,
        "missing_expected_documents" => expected_in_group.length - matched_fallback_count,
        "unexpected_txt_files" => unexpected_txt_count,
        "metadata_files_copied" => ancestor_rows.count { |row| row["exists"] == "true" },
        "samples_copied" => sample_rows.length,
        "inventory_bytes" => inventory_rows.sum { |row| row["size_bytes"].to_i },
        "scan_issues" => issues.length
      }
      File.write(group_dir.join("summary.json"), JSON.pretty_generate(summary) + "\n", mode: "w", encoding: "UTF-8")
      group_summaries << summary

      total_files += inventory_rows.length
      total_bytes += summary.fetch("inventory_bytes")
      total_samples += sample_rows.length
    end

    write_csv(@package_dir.join("all_inventory.csv"), ["group_key"] + inventory_headers, global_inventory_rows)
    write_csv(@package_dir.join("all_samples.csv"), ["group_key"] + sample_headers, global_sample_rows)
    write_csv(@package_dir.join("missing_expected_paths.csv"), %w[group_key folder_path expected_path document_id work_id], missing_expected_paths)
    write_csv(@package_dir.join("scan_issues.csv"), %w[group_key kind path error_class error_message], scan_issues)

    summary = {
      "extractor_version" => VERSION,
      "created_at" => Time.now.utc.iso8601,
      "viewer_root" => @viewer_root.to_s,
      "corpus_root" => @corpus_root.to_s,
      "id_registry" => @id_registry_path.to_s,
      "fallback_documents_report" => @fallback_documents_path.to_s,
      "fallback_works_report" => @fallback_works_path.to_s,
      "target_groups" => fallback_works.length,
      "expected_fallback_documents" => fallback_documents.length,
      "inventory_files" => total_files,
      "inventory_bytes" => total_bytes,
      "samples_copied" => total_samples,
      "missing_expected_paths" => missing_expected_paths.length,
      "scan_issues" => scan_issues.length,
      "registry" => registry_summary,
      "groups" => group_summaries
    }
    File.write(@package_dir.join("summary.json"), JSON.pretty_generate(summary) + "\n", mode: "w", encoding: "UTF-8")

    write_readme(summary)
    write_checksums
    create_ascii_safe_zip

    log "DONE"
    log "targets: #{fallback_works.length}"
    log "fallback documents expected: #{fallback_documents.length}"
    log "inventory files: #{total_files}"
    log "samples copied: #{total_samples}"
    log "missing expected paths: #{missing_expected_paths.length}"
    log "scan issues: #{scan_issues.length}"
    log "upload this ZIP: #{@zip_path}"
    log "corpus files were read but not changed"
  end

  private

  def parse_options!(argv)
    OptionParser.new do |parser|
      parser.banner = "Usage: ruby extract_fallback_id_repair_inputs.rb [options]"
      parser.on("--viewer-root PATH", "Viewer root (default: current directory)") { |value| @options[:viewer_root] = Pathname.new(value) }
      parser.on("--corpus-root PATH", "Corpus root (default: VIEWER_ROOT/../corpus)") { |value| @options[:corpus_root] = Pathname.new(value) }
      parser.on("--id-registry PATH", "Explicit metadata_id_registry.csv") { |value| @options[:id_registry] = Pathname.new(value) }
      parser.on("--output PATH", "Output root (default: VIEWER_ROOT/tmp/fallback_id_repair_extract)") { |value| @options[:output_root] = Pathname.new(value) }
      parser.on("--fallback-documents PATH", "identifier_fallback_documents.csv") { |value| @options[:fallback_documents] = Pathname.new(value) }
      parser.on("--fallback-works PATH", "identifier_fallback_works.csv") { |value| @options[:fallback_works] = Pathname.new(value) }
    end.parse!(argv)
  end

  def resolve_paths!
    @viewer_root = @options[:viewer_root].expand_path
    @corpus_root = (@options[:corpus_root] || @viewer_root.join("..", "corpus")).expand_path
    @output_root = (@options[:output_root] || @viewer_root.join("tmp", "fallback_id_repair_extract")).expand_path
    script_root = Pathname.new(__dir__).join("..").expand_path
    @fallback_documents_path = (@options[:fallback_documents] || script_root.join("data", "identifier_fallback_documents.csv")).expand_path
    @fallback_works_path = (@options[:fallback_works] || script_root.join("data", "identifier_fallback_works.csv")).expand_path
    @id_registry_path = (@options[:id_registry] || discover_registry).expand_path
    @package_dir = @output_root.join("package")
    @zip_path = @output_root.join("fallback_id_repair_inputs.zip")
  end

  def discover_registry
    candidates = Dir.glob(@viewer_root.join("tmp", "corpus_metadata_json", "full_*", "metadata_id_registry.csv").to_s)
    raise "No metadata_id_registry.csv found under #{@viewer_root}/tmp/corpus_metadata_json/full_*" if candidates.empty?

    Pathname.new(candidates.max_by { |path| [File.mtime(path), path] })
  end

  def validate_inputs!
    raise "Viewer root not found: #{@viewer_root}" unless @viewer_root.directory?
    raise "Corpus root not found: #{@corpus_root}" unless @corpus_root.directory?
    raise "Fallback document report not found: #{@fallback_documents_path}" unless @fallback_documents_path.file?
    raise "Fallback work report not found: #{@fallback_works_path}" unless @fallback_works_path.file?
    raise "ID registry not found: #{@id_registry_path}" unless @id_registry_path.file?
  end

  def prepare_output!
    FileUtils.rm_rf(@output_root)
    FileUtils.mkdir_p(@package_dir.join("groups"))
  end

  def copy_input_reports
    FileUtils.cp(@fallback_documents_path, @package_dir.join("identifier_fallback_documents.csv"))
    FileUtils.cp(@fallback_works_path, @package_dir.join("identifier_fallback_works.csv"))
  end

  def extract_registry_rows(fallback_works)
    affected_work_ids = fallback_works.filter_map do |row|
      value = row["work_id"].to_s
      value if value.match?(/\A\d+\z/)
    end.to_h { |id| [id, true] }
    folder_prefixes = fallback_works.map { |row| normalize_rel(row.fetch("folder_path")) }

    affected_rows = []
    max_work_id = 0
    max_document_id = 0
    total_rows = 0
    kind_counts = Hash.new(0)

    CSV.foreach(@id_registry_path, headers: true, encoding: "bom|utf-8") do |row|
      total_rows += 1
      kind = row["kind"].to_s
      id = row["id"].to_s
      parent_work_id = row["parent_work_id"].to_s
      path = normalize_rel(row["path"].to_s)
      kind_counts[kind] += 1

      numeric_id = id.to_i if id.match?(/\A\d+\z/)
      max_work_id = [max_work_id, numeric_id].max if kind == "work" && numeric_id
      max_document_id = [max_document_id, numeric_id].max if kind == "document" && numeric_id

      path_match = folder_prefixes.any? { |prefix| path == prefix || path.start_with?("#{prefix}/") }
      id_match = (kind == "work" && affected_work_ids[id]) || affected_work_ids[parent_work_id]
      next unless path_match || id_match

      affected_rows << row.to_h
      log "registry rows scanned: #{total_rows}" if (total_rows % 25_000).zero?
    end

    headers = if affected_rows.empty?
                CSV.open(@id_registry_path, "r:bom|utf-8", headers: true, &:readline).headers
              else
                affected_rows.first.keys
              end
    write_csv(@package_dir.join("affected_registry_rows.csv"), headers, affected_rows)

    summary = {
      "total_registry_rows" => total_rows,
      "affected_registry_rows" => affected_rows.length,
      "max_work_id" => max_work_id,
      "max_document_id" => max_document_id,
      "kind_counts" => kind_counts
    }
    File.write(@package_dir.join("registry_summary.json"), JSON.pretty_generate(summary) + "\n", mode: "w", encoding: "UTF-8")
    summary
  end

  def inventory_folder(folder_abs, folder_rel, expected_paths)
    rows = []
    issues = []
    unless folder_abs.directory?
      issues << {
        "kind" => "missing_target_folder",
        "path" => folder_rel,
        "error_class" => "",
        "error_message" => "Target folder does not exist"
      }
      return [rows, issues]
    end

    scanned = 0
    begin
      Find.find(folder_abs.to_s) do |path_string|
        path = Pathname.new(path_string)
        next if path.directory?

        begin
          stat = path.stat
          corpus_rel = normalize_rel(path.relative_path_from(@corpus_root).to_s)
          target_rel = normalize_rel(path.relative_path_from(folder_abs).to_s)
          expected = expected_paths[corpus_rel]
          rows << {
            "corpus_relative_path" => corpus_rel,
            "target_relative_path" => target_rel,
            "name" => path.basename.to_s,
            "extension" => path.extname,
            "size_bytes" => stat.size,
            "mtime_utc" => stat.mtime.utc.iso8601,
            "sha256" => Digest::SHA256.file(path).hexdigest,
            "expected_fallback" => expected ? "true" : "false",
            "expected_document_id" => expected&.fetch("document_id", "") || "",
            "expected_work_id" => expected&.fetch("work_id", "") || ""
          }
          scanned += 1
          log "files inventoried: #{scanned} in #{folder_rel}" if (scanned % PROGRESS_INTERVAL).zero?
        rescue StandardError => error
          issues << {
            "kind" => "unreadable_file",
            "path" => normalize_rel(path.to_s),
            "error_class" => error.class.name,
            "error_message" => error.message
          }
        end
      end
    rescue StandardError => error
      issues << {
        "kind" => "unreadable_directory",
        "path" => folder_rel,
        "error_class" => error.class.name,
        "error_message" => error.message
      }
    end

    [rows.sort_by { |row| row.fetch("corpus_relative_path") }, issues]
  end

  def copy_metadata_chain(folder_abs, folder_rel, group_dir)
    rows = []
    metadata_dir = group_dir.join("metadata")
    FileUtils.mkdir_p(metadata_dir)

    current = folder_abs
    level = 0
    while current.to_s.start_with?(@corpus_root.to_s)
      metadata = current.join("metadata.json")
      corpus_rel = normalize_rel(metadata.relative_path_from(@corpus_root).to_s)
      copied_as = format("ancestor_%02d.json", level)
      if metadata.file?
        destination = metadata_dir.join(copied_as)
        FileUtils.cp(metadata, destination)
        rows << {
          "level" => level,
          "corpus_relative_path" => corpus_rel,
          "copied_as" => normalize_rel(destination.relative_path_from(group_dir).to_s),
          "exists" => "true",
          "sha256" => Digest::SHA256.file(destination).hexdigest,
          "size_bytes" => destination.size
        }
      else
        rows << {
          "level" => level,
          "corpus_relative_path" => corpus_rel,
          "copied_as" => "",
          "exists" => "false",
          "sha256" => "",
          "size_bytes" => ""
        }
      end
      break if current == @corpus_root
      parent = current.parent
      break if parent == current
      current = parent
      level += 1
    end
    rows
  end

  def copy_samples(group_key, folder_abs, folder_rel, inventory_rows, group_dir)
    txt_rows = inventory_rows.select { |row| row.fetch("extension").downcase == ".txt" }
    selected = if txt_rows.length <= SMALL_GROUP_COPY_LIMIT
                 txt_rows
               else
                 sample_indices(txt_rows.length).map { |index| txt_rows.fetch(index) }
               end

    samples_dir = group_dir.join("samples")
    FileUtils.mkdir_p(samples_dir)

    selected.each_with_index.map do |row, index|
      source = @corpus_root.join(row.fetch("corpus_relative_path"))
      extension = source.extname.empty? ? ".bin" : source.extname
      copied_name = format("sample_%03d%s", index + 1, extension)
      destination = samples_dir.join(copied_name)
      FileUtils.cp(source, destination)
      {
        "copied_as" => normalize_rel(destination.relative_path_from(group_dir).to_s),
        "corpus_relative_path" => row.fetch("corpus_relative_path"),
        "size_bytes" => destination.size,
        "sha256" => Digest::SHA256.file(destination).hexdigest,
        "expected_fallback" => row.fetch("expected_fallback"),
        "expected_document_id" => row.fetch("expected_document_id"),
        "expected_work_id" => row.fetch("expected_work_id")
      }
    end
  end

  def sample_indices(length)
    return (0...length).to_a if length <= LARGE_GROUP_SAMPLE_COUNT

    [0, 1, 2, length / 2, length - 3, length - 2, length - 1].uniq.sort
  end

  def write_readme(summary)
    text = <<~TEXT
      Fallback-ID repair input extract
      =================================

      This package is read-only evidence gathered from the live corpus. It is intended
      to support one complete stable-ID and metadata repair rather than repeated guesses.

      Contents:
      - identifier_fallback_documents.csv: all #{summary.fetch("expected_fallback_documents")} fallback-ID rows.
      - identifier_fallback_works.csv: the #{summary.fetch("target_groups")} affected folder groups.
      - affected_registry_rows.csv: existing registry rows connected to those folders/work IDs.
      - registry_summary.json: current maximum stable IDs and registry counts.
      - groups/*/inventory.csv: complete filename, byte-size, mtime and SHA-256 inventory.
      - groups/*/metadata/: work and ancestor metadata.json files, copied to ASCII names.
      - groups/*/samples/: all TXT files for groups of <= #{SMALL_GROUP_COPY_LIMIT} files;
        representative beginning/middle/end samples for larger groups.
      - missing_expected_paths.csv: fallback rows absent from the live folders.
      - scan_issues.csv: read failures, if any.
      - SHA256SUMS.csv: package checksums.

      Corpus files were read but not changed.
    TEXT
    File.write(@package_dir.join("README.txt"), text, mode: "w", encoding: "UTF-8")
  end

  def write_checksums
    rows = []
    Find.find(@package_dir.to_s) do |path_string|
      path = Pathname.new(path_string)
      next if path.directory?
      next if path.basename.to_s == "SHA256SUMS.csv"
      relative = normalize_rel(path.relative_path_from(@package_dir).to_s)
      rows << {
        "path" => relative,
        "size_bytes" => path.size,
        "sha256" => Digest::SHA256.file(path).hexdigest
      }
    end
    write_csv(@package_dir.join("SHA256SUMS.csv"), %w[path size_bytes sha256], rows.sort_by { |row| row.fetch("path") })
  end

  def create_ascii_safe_zip
    non_ascii = []
    Find.find(@package_dir.to_s) do |path_string|
      path = Pathname.new(path_string)
      relative = normalize_rel(path.relative_path_from(@package_dir.parent).to_s)
      non_ascii << relative unless relative.ascii_only?
    end
    raise "Refusing to create ZIP with non-ASCII entry names: #{non_ascii.first(5).join(", ")}" unless non_ascii.empty?

    python = <<~PYTHON
      import os, sys, zipfile
      package_dir, zip_path = sys.argv[1], sys.argv[2]
      base = os.path.dirname(package_dir)
      with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
          for root, dirs, files in os.walk(package_dir):
              dirs.sort(); files.sort()
              for name in files:
                  path = os.path.join(root, name)
                  arcname = os.path.relpath(path, base).replace(os.sep, "/")
                  if not arcname.isascii():
                      raise RuntimeError(f"non-ASCII archive name: {arcname}")
                  zf.write(path, arcname)
    PYTHON
    stdout, stderr, status = Open3.capture3("python3", "-c", python, @package_dir.to_s, @zip_path.to_s)
    raise "ZIP creation failed: #{stderr}\n#{stdout}" unless status.success?
  end

  def load_csv(path)
    CSV.read(path, headers: true, encoding: "bom|utf-8").map(&:to_h)
  end

  def write_csv(path, headers, rows)
    FileUtils.mkdir_p(path.dirname)
    CSV.open(path, "w", write_headers: true, headers: headers, encoding: "UTF-8") do |csv|
      rows.each do |row|
        csv << headers.map { |header| row[header] }
      end
    end
  end

  def inventory_headers
    %w[corpus_relative_path target_relative_path name extension size_bytes mtime_utc sha256 expected_fallback expected_document_id expected_work_id]
  end

  def sample_headers
    %w[copied_as corpus_relative_path size_bytes sha256 expected_fallback expected_document_id expected_work_id]
  end

  def fallback_document_headers
    %w[doc_id document_id work_id work title folder_path path reason]
  end

  def group_key_for(row, index)
    work_id = row["work_id"].to_s
    return "work_#{work_id}" if work_id.match?(/\A\d+\z/)

    format("orphan_%03d", index + 1)
  end

  def normalize_rel(value)
    value.to_s.tr("\\", "/").sub(%r{\A\./}, "").sub(%r{/+\z}, "")
  end

  def log(message)
    $stdout.puts("[fallback-extract] #{message}")
    $stdout.flush
  end
end

FallbackIdRepairInputExtractor.new(ARGV).run
