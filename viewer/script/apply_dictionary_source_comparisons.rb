#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "yaml"

module ApplyDictionarySourceComparisons
  module_function

  Options = Struct.new(:import_plan, :output, :config, keyword_init: true)

  REGISTER_HEADERS = %w[
    repair_id dictionary_title document_id source_file source_path source_line_start
    source_line_end fanqie payload_sha256 restored_headword decision confidence
    witness_label witness_url witness_reading exact_match result note
  ].freeze

  def run(argv)
    options = parse_options(argv)
    import_plan = Pathname(options.import_plan).expand_path
    output = Pathname(options.output || import_plan.join("source_comparison")).expand_path
    config_path = Pathname(options.config || "config/dictionary_import/source_comparison_repairs.yml").expand_path
    gaps_path = import_plan.join("entries.localized_source_gaps.jsonl")
    ready_path = import_plan.join("entries.ready_for_import_review.jsonl")

    abort "Missing localized source gaps: #{gaps_path}" unless gaps_path.file?
    abort "Missing ready entries: #{ready_path}" unless ready_path.file?
    abort "Missing source-comparison config: #{config_path}" unless config_path.file?

    config = YAML.safe_load(config_path.read(encoding: "UTF-8"), aliases: false) || {}
    repairs = Array(config["repairs"])
    gaps = read_jsonl(gaps_path)
    ready = read_jsonl(ready_path)
    gaps_by_key = gaps.group_by { |entry| entry_key(entry) }

    repaired = []
    unresolved = gaps.dup
    register = []

    repairs.each do |repair|
      key = repair_key(repair)
      candidates = Array(gaps_by_key[key])
      exact = candidates.find { |entry| Digest::SHA256.hexdigest(entry.fetch("payload_raw").to_s) == repair.fetch("payload_sha256").to_s }
      approved = repair["decision"].to_s == "approved_for_import_layer"

      if exact && approved
        restored = restore_entry(exact, repair)
        repaired << restored
        unresolved.delete(exact)
        result = "restored_in_editorial_import_layer"
      elsif exact
        result = "exact_match_not_approved"
      else
        result = "no_exact_source_gap_match"
      end

      register << register_row(repair, exact, result)
    end

    duplicates = duplicate_keys(ready + repaired)
    abort "Refusing to write: duplicate import keys after source comparison: #{duplicates.first(10).join(', ')}" if duplicates.any?

    FileUtils.rm_rf(output)
    FileUtils.mkdir_p(output)
    write_jsonl(output.join("entries.source_comparison_repaired.jsonl"), repaired)
    write_jsonl(output.join("entries.source_comparison_unresolved.jsonl"), unresolved)
    write_jsonl(output.join("entries.ready_for_import_with_approved_repairs.jsonl"), ready + repaired)
    CSV.open(output.join("source_comparison_register.csv"), "wb", write_headers: true, headers: REGISTER_HEADERS, force_quotes: true) do |csv|
      register.each { |row| csv << REGISTER_HEADERS.map { |header| row[header] } }
    end

    summary = {
      "schema_version" => 1,
      "base_ready_entries" => ready.length,
      "localized_source_gaps" => gaps.length,
      "configured_comparisons" => repairs.length,
      "exact_comparisons" => register.count { |row| row["exact_match"] },
      "approved_repairs_written" => repaired.length,
      "unresolved_source_gaps" => unresolved.length,
      "combined_ready_entries" => ready.length + repaired.length,
      "corpus_files_modified" => 0,
      "database_rows_written" => 0
    }
    output.join("summary.json").write(JSON.pretty_generate(summary) + "\n", encoding: "UTF-8")
    output.join("summary.txt").write(summary_text(summary), encoding: "UTF-8")

    puts summary_text(summary)
    puts "Output: #{output}"
  end

  def parse_options(argv)
    options = Options.new
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby script/apply_dictionary_source_comparisons.rb --import-plan DIR [options]"
      opts.on("--import-plan DIR", "Existing dictionary import-plan directory") { |value| options.import_plan = value }
      opts.on("--output DIR", "Output directory") { |value| options.output = value }
      opts.on("--config FILE", "Source-comparison repair register") { |value| options.config = value }
    end
    parser.parse!(argv)
    abort parser.to_s unless options.import_plan
    options
  end

  def read_jsonl(path)
    path.open("r", encoding: "UTF-8") do |file|
      file.each_line(chomp: true).filter_map do |line|
      next if line.strip.empty?
        JSON.parse(line)
      end
    end
  end

  def write_jsonl(path, rows)
    path.open("w", encoding: "UTF-8") do |file|
      rows.each { |row| file.puts(JSON.generate(row)) }
    end
  end

  def entry_key(entry)
    [
      entry["dictionary_title"].to_s,
      entry["document_id"].to_i,
      entry["source_line_start"].to_i,
      entry["fanqie"].to_s
    ]
  end

  def repair_key(repair)
    [
      repair["dictionary_title"].to_s,
      repair["document_id"].to_i,
      repair["source_line_start"].to_i,
      repair["fanqie"].to_s
    ]
  end

  def restore_entry(entry, repair)
    headword = repair.fetch("restored_headword").to_s
    original = Marshal.load(Marshal.dump(entry))
    restored = Marshal.load(Marshal.dump(entry))
    restored["source_headword"] = original["headword"]
    restored["source_headwords"] = Array(original["headwords"])
    restored["source_headword_status"] = original["headword_status"]
    restored["source_contains_gap"] = true
    restored["headword"] = headword
    restored["headwords"] = [headword]
    restored["headword_status"] = "editorially_restored_from_comparison_witness"
    restored["contains_source_gap"] = false
    restored["parser_review_required"] = false
    restored["parser_review_reasons"] = []
    restored["dry_run_status"] = "ready_for_import_review"
    restored["editorial_repair_applied"] = true
    restored["editorial_repair"] = {
      "repair_id" => repair["repair_id"],
      "repair_kind" => "restore_missing_group_head",
      "restored_headword" => headword,
      "decision" => repair["decision"],
      "confidence" => repair["confidence"],
      "comparison_witness" => {
        "label" => repair["witness_label"],
        "url" => repair["witness_url"],
        "reading" => repair["witness_reading"]
      },
      "source_guard" => {
        "dictionary_title" => repair["dictionary_title"],
        "document_id" => repair["document_id"],
        "source_line_start" => repair["source_line_start"],
        "fanqie" => repair["fanqie"],
        "payload_sha256" => repair["payload_sha256"]
      },
      "note" => repair["note"]
    }
    restored
  end

  def register_row(repair, entry, result)
    {
      "repair_id" => repair["repair_id"],
      "dictionary_title" => repair["dictionary_title"],
      "document_id" => repair["document_id"],
      "source_file" => entry && entry["source_file"],
      "source_path" => entry && entry["source_path"],
      "source_line_start" => repair["source_line_start"],
      "source_line_end" => entry && entry["source_line_end"],
      "fanqie" => repair["fanqie"],
      "payload_sha256" => repair["payload_sha256"],
      "restored_headword" => repair["restored_headword"],
      "decision" => repair["decision"],
      "confidence" => repair["confidence"],
      "witness_label" => repair["witness_label"],
      "witness_url" => repair["witness_url"],
      "witness_reading" => repair["witness_reading"],
      "exact_match" => !entry.nil?,
      "result" => result,
      "note" => repair["note"]
    }
  end

  def duplicate_keys(rows)
    seen = {}
    duplicates = []
    rows.each do |row|
      key = [row["dictionary_work_id"], row["document_id"], row["sequence_number"]].join(":")
      duplicates << key if seen[key]
      seen[key] = true
    end
    duplicates.uniq
  end

  def summary_text(summary)
    <<~TEXT
      DICTIONARY SOURCE COMPARISON — EDITORIAL IMPORT LAYER
      =====================================================
      Base ready entries:             #{summary['base_ready_entries']}
      Localized source gaps:           #{summary['localized_source_gaps']}
      Configured comparisons:          #{summary['configured_comparisons']}
      Exact comparisons:               #{summary['exact_comparisons']}
      Approved repairs written:        #{summary['approved_repairs_written']}
      Unresolved source gaps:           #{summary['unresolved_source_gaps']}
      Combined ready entries:          #{summary['combined_ready_entries']}
      Corpus files modified:           #{summary['corpus_files_modified']}
      Database rows written:            #{summary['database_rows_written']}
    TEXT
  end
end

ApplyDictionarySourceComparisons.run(ARGV) if $PROGRAM_NAME == __FILE__
