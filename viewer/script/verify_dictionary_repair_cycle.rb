#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "json"
require "optparse"
require "pathname"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

module VerifyDictionaryRepairCycle
  module_function

  Options = Struct.new(:import_plan, :output, :title, :expected_entries, keyword_init: true)

  def run(argv)
    options = parse_options(argv)
    import_plan = Pathname(options.import_plan).expand_path
    output = Pathname(options.output || import_plan.join("repair_cycle_verification")).expand_path
    title = (options.title || "洪武正韻").dup.force_encoding(Encoding::UTF_8)
    expected_entries = Integer(options.expected_entries || 14_379)

    work_summary_path = import_plan.join("work_summary.csv")
    ready_path = import_plan.join("entries.ready_for_import_review.jsonl")
    gaps_path = import_plan.join("entries.localized_source_gaps.jsonl")

    abort "Missing work summary: #{work_summary_path}" unless work_summary_path.file?
    abort "Missing ready entries: #{ready_path}" unless ready_path.file?
    abort "Missing localized gaps: #{gaps_path}" unless gaps_path.file?

    work_rows = CSV.read(work_summary_path, headers: true, encoding: "bom|utf-8").map(&:to_h)
    work = work_rows.find { |row| row["configured_title"] == title }
    abort "#{title} not found in work summary" unless work

    ready_entries = read_jsonl(ready_path).select { |row| row["dictionary_title"] == title || row["configured_title"] == title }
    gap_entries = read_jsonl(gaps_path).select { |row| row["dictionary_title"] == title || row["configured_title"] == title }

    checks = {
      "work_status_ready" => work["status"] == "ready_for_import_review",
      "entry_count_matches" => work["entries"].to_i == expected_entries,
      "ready_jsonl_count_matches" => ready_entries.length == expected_entries,
      "no_localized_source_gaps" => work["source_gap_entries"].to_i.zero? && gap_entries.empty?,
      "no_unmatched_payloads" => work["unmatched_payloads"].to_i.zero?,
      "no_unmatched_head_groups" => work["unmatched_head_groups"].to_i.zero?,
      "no_parser_warnings" => work["warning_count"].to_i.zero?
    }

    summary = {
      "dictionary_title" => title,
      "expected_entries" => expected_entries,
      "reported_entries" => work["entries"].to_i,
      "ready_jsonl_entries" => ready_entries.length,
      "localized_source_gaps" => gap_entries.length,
      "work_status" => work["status"],
      "checks" => checks,
      "passed" => checks.values.all?,
      "metadata_files_modified" => 0,
      "database_rows_written" => 0
    }

    output.mkpath
    output.join("summary.json").write(JSON.pretty_generate(summary) + "\n", encoding: "UTF-8")
    output.join("summary.txt").write(summary_text(summary), encoding: "UTF-8")
    puts JSON.pretty_generate(summary)
    abort "Post-repair parser verification failed. Review #{output}" unless summary["passed"]
  end

  def read_jsonl(path)
    path.each_line.filter_map do |line|
      stripped = line.strip
      next if stripped.empty?
      JSON.parse(stripped)
    end
  end

  def parse_options(argv)
    options = Options.new
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby script/verify_dictionary_repair_cycle.rb --import-plan DIR [options]"
      opts.on("--import-plan DIR", "Post-repair import-plan directory") { |value| options.import_plan = value }
      opts.on("--output DIR", "Verification output directory") { |value| options.output = value }
      opts.on("--title TITLE", "Dictionary title, default 洪武正韻") { |value| options.title = value }
      opts.on("--expected-entries N", Integer, "Expected entry count, default 14379") { |value| options.expected_entries = value }
      opts.on("-h", "--help", "Show help") { puts opts; exit 0 }
    end
    parser.parse!(argv)
    abort parser.to_s unless options.import_plan
    abort "Unexpected arguments: #{argv.join(' ')}" unless argv.empty?
    options
  end

  def summary_text(summary)
    lines = [
      "POST-REPAIR DICTIONARY VERIFICATION",
      "===================================",
      "Dictionary:                  #{summary['dictionary_title']}",
      "Expected entries:            #{summary['expected_entries']}",
      "Reported entries:            #{summary['reported_entries']}",
      "Ready JSONL entries:         #{summary['ready_jsonl_entries']}",
      "Localized source gaps:       #{summary['localized_source_gaps']}",
      "Work status:                 #{summary['work_status']}",
      "Passed:                      #{summary['passed']}",
      "Metadata files modified:     #{summary['metadata_files_modified']}",
      "Database rows written:       #{summary['database_rows_written']}",
      "",
      "Checks:"
    ]
    summary.fetch("checks").each { |name, passed| lines << "  #{name}: #{passed}" }
    lines.join("\n") + "\n"
  end
end

VerifyDictionaryRepairCycle.run(ARGV) if $PROGRAM_NAME == __FILE__
