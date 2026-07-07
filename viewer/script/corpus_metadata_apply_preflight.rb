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

# Builds a non-destructive apply plan for JSON metadata output.
#
# Important: this script does not write corpus files. It checks where
# metadata.json would be written, which txt files would be moved into contained
# work folders, and whether any collisions/overwrites would occur.
class CorpusMetadataApplyPreflight
  attr_reader :options

  REQUIRED_FILES = %w[
    staged_metadata.jsonl
    work_manifest.csv
    contained_work_proposals.csv
    metadata_conflicts.csv
    unknown_legacy_rows.csv
  ].freeze

  def initialize(options)
    @options = options
    @dry_run_output = Pathname(options.fetch(:dry_run_output)).expand_path
    @corpus_root = Pathname(options.fetch(:corpus_root)).expand_path
    @output_root = Pathname(options.fetch(:output)).expand_path
    @progress_every = options.fetch(:progress_every).to_i
    @started_at = Time.now.utc

    @record_ids = Set.new
    @work_rows = []
    @contained_rows = []
    @metadata_writes = []
    @moves = []
    @skips = []
    @overwrites = []
    @identical_text_merges = []
  end

  def run
    progress "validating inputs"
    validate!
    FileUtils.mkdir_p(@output_root)
    progress "loading staged metadata ids"
    load_record_ids!
    progress "loading work manifest"
    load_work_manifest!
    progress "loading contained-work proposals"
    load_contained_work_proposals!
    progress "building apply plan"
    build_plan!
    progress "writing reports"
    write_reports!
    progress "finished"
    warn "[metadata-preflight] checked #{@metadata_writes.length} metadata writes and #{@moves.length} txt moves"
  end

  private

  def validate!
    raise ArgumentError, "Dry-run output does not exist: #{@dry_run_output}" unless @dry_run_output.directory?
    REQUIRED_FILES.each do |name|
      path = @dry_run_output.join(name)
      raise ArgumentError, "Missing #{name} in #{@dry_run_output}; rerun JSON dry-run with the latest script" unless path.file?
    end
    raise ArgumentError, "Corpus root does not exist: #{@corpus_root}" unless @corpus_root.directory?
  end

  def progress(message)
    warn "[metadata-preflight] #{Time.now.utc.iso8601} #{message}"
  end

  def maybe_progress(count, label)
    return unless @progress_every.positive?
    return unless (count % @progress_every).zero?

    progress "#{label}: #{count}"
  end

  def load_record_ids!
    count = 0
    File.foreach(@dry_run_output.join("staged_metadata.jsonl"), encoding: "UTF-8") do |line|
      next if line.strip.empty?
      payload = JSON.parse(line)
      @record_ids << payload.fetch("work_id").to_s
      count += 1
      maybe_progress(count, "metadata records read")
    end
  end

  def load_work_manifest!
    CSV.foreach(@dry_run_output.join("work_manifest.csv"), headers: true, encoding: "bom|utf-8") do |row|
      @work_rows << row.to_h
    end
  end

  def load_contained_work_proposals!
    CSV.foreach(@dry_run_output.join("contained_work_proposals.csv"), headers: true, encoding: "bom|utf-8") do |row|
      @contained_rows << row.to_h
    end
  end

  def build_plan!
    validate_source_reports!
    build_folder_work_plan!
    build_contained_work_plan!
  end

  def validate_source_reports!
    conflict_count = csv_row_count(@dry_run_output.join("metadata_conflicts.csv"))
    unknown_count = csv_row_count(@dry_run_output.join("unknown_legacy_rows.csv"))
    add_skip("dry_run_conflicts", nil, nil, "metadata_conflicts.csv has #{conflict_count} rows") if conflict_count.positive?
    add_skip("unknown_legacy_rows", nil, nil, "unknown_legacy_rows.csv has #{unknown_count} rows") if unknown_count.positive?
  end

  def build_folder_work_plan!
    @work_rows.each_with_index do |row, index|
      work_id = row.fetch("work_id").to_s
      unless @record_ids.include?(work_id)
        add_skip("missing_json_record", work_id, row["folder"], "No staged JSON record exists for folder work")
        next
      end

      metadata_path = @corpus_root.join(row.fetch("folder")).join("metadata.json")
      note_overwrite(metadata_path, work_id, row["title"]) if metadata_path.exist?
      add_metadata_write(
        kind: "folder_work",
        action: "write_metadata_json",
        work_id: work_id,
        title: row["title"],
        folder: row["folder"],
        metadata_path: metadata_path,
        source: "work_manifest"
      )
      maybe_progress(index + 1, "folder work plans")
    end
  end

  def build_contained_work_plan!
    @contained_rows.each_with_index do |row, index|
      work_id = row.fetch("contained_work_id").to_s
      target_folder = presence(row["target_folder"])
      if target_folder.nil?
        add_skip("missing_target_folder", work_id, row["title"], "contained_work_proposals.csv lacks target_folder; rerun JSON dry-run")
        next
      end
      unless @record_ids.include?(work_id)
        add_skip("missing_json_record", work_id, row["title"], "No staged JSON record exists for contained work")
        next
      end

      if row["folderisation_action"].to_s == "folderise_cross_folder_review"
        add_skip(
          "folderise_cross_folder_review",
          work_id,
          row["title"],
          "Contained work would move txt files from multiple source folders; fix grouping or review manually before applying"
        )
        next
      end

      metadata_path = @corpus_root.join(target_folder).join("metadata.json")
      note_overwrite(metadata_path, work_id, row["title"]) if metadata_path.exist?
      add_metadata_write(
        kind: "contained_work",
        action: row["folderisation_action"].to_s == "existing_work_folder" ? "write_metadata_json" : "folderise_and_write_metadata_json",
        work_id: work_id,
        title: row["title"],
        folder: target_folder,
        metadata_path: metadata_path,
        source: "contained_work_proposals"
      )

      source_paths = split_pipe(row["source_paths"])
      target_paths = split_pipe(row["target_paths"])
      if source_paths.length != target_paths.length
        add_skip("source_target_count_mismatch", work_id, row["title"], "#{source_paths.length} source paths vs #{target_paths.length} target paths")
        next
      end

      source_paths.zip(target_paths).each do |source_rel, target_rel|
        next if source_rel == target_rel

        source_abs = @corpus_root.join(source_rel)
        target_abs = @corpus_root.join(target_rel)

        unless source_abs.file?
          add_skip("missing_source_txt", work_id, source_rel, "Source txt does not exist")
          next
        end

        if target_abs.exist? && source_abs.expand_path != target_abs.expand_path
          if target_abs.file? && same_text_body?(source_abs, target_abs)
            add_identical_text_merge(work_id, row["title"], source_rel, target_rel, source_abs, target_abs)
            next
          end

          add_skip(
            "target_txt_exists_different_content",
            work_id,
            "#{source_rel} -> #{target_rel}",
            "Target txt already exists and its text body is not byte-identical; do not choose by timestamp automatically"
          )
          next
        end

        @moves << {
          work_id: work_id,
          title: row["title"],
          source_path: source_rel,
          target_path: target_rel,
          source_abs: source_abs.to_s,
          target_abs: target_abs.to_s,
          action: "move_txt_into_work_folder"
        }
      end
      maybe_progress(index + 1, "contained work plans")
    end
  end

  def add_metadata_write(kind:, action:, work_id:, title:, folder:, metadata_path:, source:)
    @metadata_writes << {
      kind: kind,
      action: action,
      work_id: work_id,
      title: title,
      folder: folder,
      metadata_path: metadata_path.to_s,
      relative_metadata_path: metadata_path.relative_path_from(@corpus_root).to_s,
      source: source
    }
  end

  def note_overwrite(path, work_id, title)
    @overwrites << {
      work_id: work_id,
      title: title,
      metadata_path: path.to_s,
      relative_metadata_path: path.relative_path_from(@corpus_root).to_s,
      reason: "metadata_json_already_exists"
    }
  end

  def add_identical_text_merge(work_id, title, source_rel, target_rel, source_abs, target_abs)
    source_mtime = source_abs.mtime.utc
    target_mtime = target_abs.mtime.utc
    keep_path = source_mtime > target_mtime ? source_rel : target_rel
    remove_path = keep_path == source_rel ? target_rel : source_rel
    action = keep_path == source_rel ? "replace_target_with_newer_source" : "remove_older_source_keep_target"

    @identical_text_merges << {
      work_id: work_id,
      title: title,
      source_path: source_rel,
      target_path: target_rel,
      source_abs: source_abs.to_s,
      target_abs: target_abs.to_s,
      keep_path: keep_path,
      remove_path: remove_path,
      action: action,
      reason: "target_exists_same_text",
      source_mtime: source_mtime.iso8601,
      target_mtime: target_mtime.iso8601,
      source_file_sha256: Digest::SHA256.file(source_abs).hexdigest,
      target_file_sha256: Digest::SHA256.file(target_abs).hexdigest,
      text_sha256: Digest::SHA256.hexdigest(text_body_bytes(source_abs))
    }
  end

  def add_skip(reason, work_id, path, message)
    @skips << { reason: reason, work_id: work_id, path: path, message: message }
  end

  def write_reports!
    write_apply_plan
    write_metadata_writes
    write_moves
    write_identical_text_merges
    write_contained_folderisation_plan
    write_overwrites
    write_skips
    write_summary
    write_report_md
  end

  def write_apply_plan
    headers = %w[kind action work_id title source_path target_path metadata_path issue]
    CSV.open(@output_root.join("apply_plan.csv"), "w", write_headers: true, headers: headers) do |csv|
      @metadata_writes.each do |row|
        csv << [row[:kind], row[:action], row[:work_id], row[:title], nil, nil, row[:relative_metadata_path], nil]
      end
      @moves.each do |row|
        csv << ["txt_move", row[:action], row[:work_id], row[:title], row[:source_path], row[:target_path], nil, nil]
      end
      @identical_text_merges.each do |row|
        csv << ["txt_dedupe", row[:action], row[:work_id], row[:title], row[:source_path], row[:target_path], nil, "same text body; metadata will be merged"]
      end
      @skips.each do |row|
        csv << ["problem", row[:reason], row[:work_id], nil, row[:path], nil, nil, row[:message]]
      end
    end
  end

  def write_metadata_writes
    headers = %w[kind action work_id title folder relative_metadata_path metadata_path source]
    CSV.open(@output_root.join("would_write_metadata_json.csv"), "w", write_headers: true, headers: headers) do |csv|
      @metadata_writes.each { |row| csv << headers.map { |key| row[key.to_sym] } }
    end
  end

  def write_moves
    headers = %w[work_id title action source_path target_path source_abs target_abs]
    CSV.open(@output_root.join("would_move_txt_files.csv"), "w", write_headers: true, headers: headers) do |csv|
      @moves.each { |row| csv << headers.map { |key| row[key.to_sym] } }
    end
  end

  def write_identical_text_merges
    headers = %w[work_id title source_path target_path keep_path remove_path action reason source_mtime target_mtime source_file_sha256 target_file_sha256 text_sha256 source_abs target_abs]
    CSV.open(@output_root.join("would_merge_identical_txt_files.csv"), "w", write_headers: true, headers: headers) do |csv|
      @identical_text_merges.each { |row| csv << headers.map { |key| row[key.to_sym] } }
    end
  end

  def write_contained_folderisation_plan
    headers = %w[contained_work_id edition_id compilation_work_id compilation_title title document_count folderisation_action target_folder metadata_destination source_paths target_paths review_note]
    CSV.open(@output_root.join("contained_work_folderisation_plan.csv"), "w", write_headers: true, headers: headers) do |csv|
      @contained_rows.each { |row| csv << headers.map { |key| row[key] } }
    end
  end

  def write_overwrites
    headers = %w[work_id title relative_metadata_path metadata_path reason]
    CSV.open(@output_root.join("would_overwrite.csv"), "w", write_headers: true, headers: headers) do |csv|
      @overwrites.each { |row| csv << headers.map { |key| row[key.to_sym] } }
    end
  end

  def write_skips
    headers = %w[reason work_id path message]
    CSV.open(@output_root.join("would_skip.csv"), "w", write_headers: true, headers: headers) do |csv|
      @skips.each { |row| csv << headers.map { |key| row[key.to_sym] } }
    end
  end

  def write_summary
    payload = {
      started_at: @started_at.iso8601,
      finished_at: Time.now.utc.iso8601,
      dry_run_output: @dry_run_output.to_s,
      corpus_root: @corpus_root.to_s,
      output_root: @output_root.to_s,
      metadata_records_checked: @record_ids.length,
      folder_work_metadata_writes: @metadata_writes.count { |row| row[:kind] == "folder_work" },
      contained_work_metadata_writes: @metadata_writes.count { |row| row[:kind] == "contained_work" },
      txt_moves: @moves.length,
      identical_text_merges: @identical_text_merges.length,
      overwrites: @overwrites.length,
      problems: @skips.length
    }
    @output_root.join("apply_preflight_summary.json").write(JSON.pretty_generate(payload) + "\n")
  end

  def write_report_md
    text = <<~MD
      # JSON metadata apply preflight

      - Dry-run output: `#{@dry_run_output}`
      - Corpus root: `#{@corpus_root}`
      - Metadata records checked: #{@record_ids.length}
      - Folder metadata writes: #{@metadata_writes.count { |row| row[:kind] == "folder_work" }}
      - Contained-work metadata writes: #{@metadata_writes.count { |row| row[:kind] == "contained_work" }}
      - Txt moves into work folders: #{@moves.length}
      - Identical text collisions to merge: #{@identical_text_merges.length}
      - Existing metadata.json overwrites: #{@overwrites.length}
      - Problems/skips: #{@skips.length}

      Rule used here:

      - Every work gets its own folder.
      - `metadata.json` is written beside that work's `.txt` files.
      - If a contained work is flat inside a compilation folder, the plan creates a folder for that work and moves only that work's txt files into it.
      - If a target txt already exists with the same text body, the newer physical file is kept and source/reference metadata is merged.
      - If the text body differs, the row remains a hard problem in `would_skip.csv`.
      - This report is non-destructive. It does not create folders, move txt files, delete duplicate txt files, or write metadata.

      Main reports:

      - `would_write_metadata_json.csv`
      - `would_move_txt_files.csv`
      - `would_merge_identical_txt_files.csv`
      - `contained_work_folderisation_plan.csv`
      - `would_overwrite.csv`
      - `would_skip.csv`
      - `apply_plan.csv`
    MD
    @output_root.join("APPLY_PREFLIGHT_REPORT.md").write(text)
  end

  def same_text_body?(left, right)
    return false unless left.file? && right.file?

    text_body_bytes(left) == text_body_bytes(right)
  rescue SystemCallError
    false
  end

  # Compare the actual text body, not old leading metadata comments. This lets
  # files with the same text but different legacy REFERENCES/SOURCE_URL/etc.
  # merge safely during folderisation.
  def text_body_bytes(path)
    content = path.binread
    lines = content.lines
    index = 0
    index += 1 while index < lines.length && lines[index].start_with?("#")
    index += 1 while index < lines.length && lines[index].strip.empty?
    lines[index..]&.join || ""
  end

  def csv_row_count(path)
    return 0 unless path.file?

    count = 0
    CSV.foreach(path, headers: true, encoding: "bom|utf-8") { |_row| count += 1 }
    count
  end

  def split_pipe(value)
    value.to_s.split("|").map(&:strip).reject(&:empty?)
  end

  def presence(value)
    text = value.to_s.strip
    text.empty? ? nil : text
  end
end

options = {
  progress_every: 25_000
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby script/corpus_metadata_apply_preflight.rb --dry-run-output DIR --corpus-root DIR --output DIR [options]"
  opts.on("--dry-run-output DIR", "Directory produced by corpus_metadata_json_dry_run.rb") { |value| options[:dry_run_output] = value }
  opts.on("--corpus-root DIR", "Corpus root") { |value| options[:corpus_root] = value }
  opts.on("--output DIR", "Output directory") { |value| options[:output] = value }
  opts.on("--progress-every N", Integer, "Print progress every N rows. Default: 25000; 0 disables") { |value| options[:progress_every] = value }
end

parser.parse!(ARGV)
missing = %i[dry_run_output corpus_root output].select { |key| options[key].to_s.empty? }
if missing.any?
  warn parser
  abort "Missing required option(s): #{missing.join(', ')}"
end

CorpusMetadataApplyPreflight.new(options).run
