#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
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
    @progress_every = options.fetch(:progress_every).to_i
    @started_at = Time.now.utc
    @records_by_work_id = {}
    @moves = []
    @writes = []
    @identical_text_merges = []
    @document_index = Hash.new { |hash, key| hash[key] = [] }
  end

  def run
    progress "validating inputs"
    validate!
    progress "loading staged metadata"
    load_metadata_records!
    progress "loading preflight move/write plans"
    load_preflight!
    progress "merging identical-text duplicate metadata"
    merge_identical_text_metadata!
    progress @apply ? "applying identical-text deduplication" : "dry-run identical-text deduplication"
    apply_identical_text_dedupes!
    progress @apply ? "applying txt moves" : "dry-run txt moves"
    apply_moves!
    progress @apply ? "writing metadata.json files" : "dry-run metadata writes"
    apply_metadata_writes!
    progress "finished"
    warn "[metadata-apply] mode=#{@apply ? 'APPLY' : 'DRY RUN'} duplicate_merges=#{@identical_text_merges.length} moves=#{@moves.length} metadata_writes=#{@writes.length}"
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
      maybe_progress(index + 1, "identical-text dedupes processed")
    end
  end

  def apply_moves!
    @moves.each_with_index do |row, index|
      source = @corpus_root.join(row.fetch("source_path"))
      target = @corpus_root.join(row.fetch("target_path"))
      if @apply
        raise "Missing source txt during apply: #{source}" unless source.file?
        raise "Target already exists during apply: #{target}" if target.exist? && source.expand_path != target.expand_path

        FileUtils.mkdir_p(target.dirname)
        FileUtils.mv(source, target) unless source.expand_path == target.expand_path
      end
      maybe_progress(index + 1, "txt moves processed")
    end
  end

  def apply_metadata_writes!
    @writes.each_with_index do |row, index|
      work_id = row.fetch("work_id").to_s
      payload = @records_by_work_id.fetch(work_id) { raise "No staged metadata record for work_id=#{work_id}" }
      destination = @corpus_root.join(row.fetch("relative_metadata_path"))
      if @apply
        if destination.exist? && !@allow_overwrite
          raise "Refusing to overwrite existing metadata.json: #{destination}"
        end
        FileUtils.mkdir_p(destination.dirname)
        atomic_write_json(destination, payload)
      end
      maybe_progress(index + 1, "metadata writes processed")
    end
  end

  def atomic_write_json(destination, payload)
    temp = destination.dirname.join(".#{destination.basename}.tmp-#{$$}")
    temp.write(JSON.pretty_generate(payload) + "\n")
    File.rename(temp, destination)
  ensure
    FileUtils.rm_f(temp) if temp && temp.exist?
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
  progress_every: 25_000
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby script/corpus_metadata_apply_json.rb --dry-run-output DIR --preflight-output DIR --corpus-root DIR [--apply]"
  opts.on("--dry-run-output DIR", "Directory produced by corpus_metadata_json_dry_run.rb") { |value| options[:dry_run_output] = value }
  opts.on("--preflight-output DIR", "Directory produced by corpus_metadata_apply_preflight.rb") { |value| options[:preflight_output] = value }
  opts.on("--corpus-root DIR", "Corpus root") { |value| options[:corpus_root] = value }
  opts.on("--apply", "Actually move txt files and write metadata.json files") { options[:apply] = true }
  opts.on("--allow-overwrite", "Allow overwriting existing metadata.json files after reviewing would_overwrite.csv") { options[:allow_overwrite] = true }
  opts.on("--progress-every N", Integer, "Print progress every N rows. Default: 25000; 0 disables") { |value| options[:progress_every] = value }
end

parser.parse!(ARGV)
missing = %i[dry_run_output preflight_output corpus_root].select { |key| options[key].to_s.empty? }
if missing.any?
  warn parser
  abort "Missing required option(s): #{missing.join(', ')}"
end

CorpusMetadataApplyJson.new(options).run
