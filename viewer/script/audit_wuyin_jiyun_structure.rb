#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "time"

# Zero-write audit for the corrected 五音集韻 parser.
#
# Important distinction:
# - structural blockers mean the parser has not understood the work safely;
# - source-quality findings mean the structure is usable, but the scrape has an
#   omitted fanqie or a damaged/missing group-count suffix.
#
# The latter remain visible and repairable. They do not force 46,000 otherwise
# coherent entries back into quarantine.
module AuditWuyinJiyunStructure
  module_function

  Options = Struct.new(:import_plan, :output, keyword_init: true)

  EXPECTED_SECTION_COUNTS = {
    "平聲" => 44,
    "上聲" => 43,
    "去聲" => 47,
    "入聲" => 26
  }.freeze
  ENTRY_FILES = %w[
    entries.reference_control.jsonl
    entries.ready_for_import_review.jsonl
    entries.candidate_review.jsonl
    entries.quarantined.jsonl
    entries.localized_source_gaps.jsonl
  ].freeze
  DIVISIONS = %w[一 二 三 四].freeze
  SOURCE_FINDING_WARNING_KINDS = %w[
    group_head_without_declared_count
    declared_group_count_mismatch
    head_group_replaced
  ].freeze

  def run(argv)
    options = parse_options(argv)
    import_plan = Pathname(options.import_plan).expand_path
    output = Pathname(options.output || import_plan.join("wuyin_structure_audit")).expand_path

    %w[work_summary.csv groups.review.csv sections.review.csv warnings.csv].each do |name|
      path = import_plan.join(name)
      abort "Required import-plan report missing: #{path}" unless path.file?
    end

    FileUtils.rm_rf(output) if output.directory?
    FileUtils.mkdir_p(output)

    works = read_csv(import_plan.join("work_summary.csv")).select { |row| row["configured_title"] == "五音集韻" }
    abort "五音集韻 was not found in work_summary.csv" unless works.length == 1
    work = works.first
    groups = read_csv(import_plan.join("groups.review.csv")).select { |row| row["configured_title"] == "五音集韻" }
    sections = read_csv(import_plan.join("sections.review.csv")).select { |row| row["configured_title"] == "五音集韻" }
    warnings = read_csv(import_plan.join("warnings.csv")).select { |row| row["configured_title"] == "五音集韻" }
    entries = load_entries(import_plan).select { |row| row["dictionary_title"] == "五音集韻" }

    section_inventory = build_section_inventory(sections)
    groups_without_reading = groups.select { |row| row["pronunciation_marker_raw"].to_s.empty? }
    groups_without_count = groups.select { |row| row["declared_group_size"].to_s.empty? }
    count_mismatches = groups.select { |row| row["declared_count_match"].to_s == "false" }
    malformed_group_heads = groups.select { |row| row["group_head_record_count"].to_i != 1 }
    contamination = entries.select { |entry| structurally_contaminated?(entry) }
    missing_tone = entries.select { |entry| entry["tone"].to_s.empty? }
    unexpected_warnings = warnings.reject { |row| SOURCE_FINDING_WARNING_KINDS.include?(row["kind"]) }

    blockers = []
    findings = []

    actual_section_total = sections.length
    blockers << item("section_total", "expected=160 actual=#{actual_section_total}") unless actual_section_total == 160
    EXPECTED_SECTION_COUNTS.each do |tone, expected|
      actual = section_inventory.count { |row| row["tone"] == tone }
      blockers << item("tone_section_count", "tone=#{tone} expected=#{expected} actual=#{actual}") unless actual == expected
    end
    blockers << item("pronunciation_group_floor", "expected_at_least=3500 actual=#{groups.length}") if groups.length < 3_500
    blockers << item("malformed_group_heads", "count=#{malformed_group_heads.length}") if malformed_group_heads.any?
    blockers << item("structural_headword_contamination", "count=#{contamination.length}") if contamination.any?
    blockers << item("entries_without_tone", "count=#{missing_tone.length}") if missing_tone.any?
    blockers << item("unexpected_parser_warnings", "count=#{unexpected_warnings.length}") if unexpected_warnings.any?
    blockers << item("unmatched_payloads", "count=#{work['unmatched_payloads']}") if work["unmatched_payloads"].to_i.positive?
    blockers << item("source_gap_entries", "count=#{work['source_gap_entries']}") if work["source_gap_entries"].to_i.positive?

    findings << item("groups_without_pronunciation_marker", "count=#{groups_without_reading.length}") if groups_without_reading.any?
    findings << item("groups_without_declared_count", "count=#{groups_without_count.length}") if groups_without_count.any?
    findings << item("declared_group_count_mismatches", "count=#{count_mismatches.length}") if count_mismatches.any?
    findings << item("unmatched_head_groups", "count=#{work['unmatched_head_groups']}") if work["unmatched_head_groups"].to_i.positive?

    write_csv(output.join("section_inventory.csv"), section_headers, section_inventory)
    write_csv(output.join("groups_without_reading.csv"), group_headers, groups_without_reading)
    write_csv(output.join("groups_without_declared_count.csv"), group_headers, groups_without_count)
    write_csv(output.join("declared_group_count_mismatches.csv"), group_headers, count_mismatches)
    write_csv(output.join("malformed_group_heads.csv"), group_headers, malformed_group_heads)
    write_csv(
      output.join("structural_headword_contamination.csv"),
      %w[dictionary_title document_id source_file source_path source_line_start source_line_end sequence_number tone rhyme_number rhyme_label initial group_sequence headwords headword fanqie payload_raw],
      contamination.map { |entry| entry_for_csv(entry) }
    )
    write_csv(
      output.join("entries_without_tone.csv"),
      %w[dictionary_title document_id source_file source_path source_line_start source_line_end sequence_number headwords headword payload_raw],
      missing_tone.map { |entry| entry_for_csv(entry) }
    )
    write_csv(output.join("parser_warnings.csv"), %w[configured_title document_id file line kind detail], warnings)
    write_csv(output.join("unexpected_parser_warnings.csv"), %w[configured_title document_id file line kind detail], unexpected_warnings)
    write_csv(output.join("structural_blockers.csv"), %w[kind detail], blockers)
    write_csv(output.join("source_quality_findings.csv"), %w[kind detail], findings)

    reading_groups = groups.length - groups_without_reading.length
    reading_coverage = groups.empty? ? 0.0 : reading_groups.fdiv(groups.length)
    summary = {
      "version" => 2,
      "mode" => "zero_write_structure_audit",
      "created_at" => Time.now.utc.iso8601,
      "dictionary_title" => "五音集韻",
      "parser_name" => work["parser"],
      "work_status" => work["status"],
      "entries" => entries.length,
      "sections" => sections.length,
      "sections_by_tone" => EXPECTED_SECTION_COUNTS.keys.to_h do |tone|
        [tone, section_inventory.count { |row| row["tone"] == tone }]
      end,
      "pronunciation_groups" => groups.length,
      "groups_with_pronunciation_marker" => reading_groups,
      "groups_without_pronunciation_marker" => groups_without_reading.length,
      "reading_coverage_percent" => (reading_coverage * 100).round(3),
      "groups_without_declared_count" => groups_without_count.length,
      "declared_group_count_mismatches" => count_mismatches.length,
      "structural_headword_contamination" => contamination.length,
      "entries_without_tone" => missing_tone.length,
      "parser_warnings" => warnings.length,
      "unexpected_parser_warnings" => unexpected_warnings.length,
      "unmatched_payloads" => work["unmatched_payloads"].to_i,
      "unmatched_head_groups" => work["unmatched_head_groups"].to_i,
      "structural_blockers" => blockers.length,
      "source_quality_findings" => findings.length,
      "ready_to_replace_existing_import" => blockers.empty? && work["status"] == "ready_for_import_review",
      "recommended_database_action" => blockers.empty? ? "run_database_plan_then_transactional_replace" : "do_not_replace_existing_import",
      "corpus_writes" => 0,
      "database_writes" => 0
    }
    output.join("summary.json").write(JSON.pretty_generate(summary) + "\n")
    output.join("summary.txt").write(summary_text(summary))

    puts summary_text(summary)
    puts "Reports: #{output}"
    blockers.empty? ? 0 : 1
  end

  def build_section_inventory(sections)
    sections.sort_by { |row| [row["document_id"].to_i, row["section_sequence"].to_i] }.map do |row|
      {
        "document_id" => row["document_id"],
        "source_file" => row["source_file"],
        "section_sequence" => row["section_sequence"],
        "tone" => row["tone"],
        "rhyme_number" => row["rhyme_number"],
        "rhyme_label" => row["rhyme_label"],
        "initial" => row["initial"],
        "entry_record_count" => row["entry_record_count"],
        "headword_count" => row["headword_count"],
        "group_count" => row["group_count"],
        "groups_without_pronunciation_marker" => row["groups_without_pronunciation_marker"],
        "declared_group_count" => row["declared_group_count"],
        "declared_group_mismatch_count" => row["declared_group_mismatch_count"],
        "requires_review" => row["requires_review"],
        "review_reasons" => row["review_reasons"]
      }
    end
  end

  def structurally_contaminated?(entry)
    heads = Array(entry["headwords"])
    heads.length > 1 && DIVISIONS.include?(heads.first)
  end

  def entry_for_csv(entry)
    entry.merge("headwords" => Array(entry["headwords"]).join)
  end

  def section_headers
    %w[document_id source_file section_sequence tone rhyme_number rhyme_label initial entry_record_count headword_count group_count groups_without_pronunciation_marker declared_group_count declared_group_mismatch_count requires_review review_reasons]
  end

  def group_headers
    %w[
      configured_title dictionary_work_id document_id source_file source_path section_sequence
      tone tone_section rhyme_number rhyme_label initial group_sequence small_rime_number
      group_head_record_count group_headword group_headwords fanqie pronunciation_marker_raw
      pronunciation_marker_type entry_record_count headword_count declared_group_size
      declared_count_match source_line_start source_line_end contains_unresolved_glyph
      requires_review review_reasons
    ]
  end

  def load_entries(import_plan)
    ENTRY_FILES.flat_map do |name|
      path = import_plan.join(name)
      next [] unless path.file?

      File.foreach(path, encoding: "utf-8").filter_map do |line|
        stripped = line.strip
        JSON.parse(stripped) unless stripped.empty?
      end
    end
  end

  def read_csv(path)
    CSV.read(path, headers: true, encoding: "bom|utf-8").map(&:to_h)
  end

  def write_csv(path, headers, rows)
    FileUtils.mkdir_p(path.dirname)
    CSV.open(path, "wb:utf-8", write_headers: true, headers: headers, force_quotes: true) do |csv|
      rows.each { |row| csv << headers.map { |header| row[header] } }
    end
  end

  def item(kind, detail)
    { "kind" => kind, "detail" => detail }
  end

  def summary_text(summary)
    tones = summary.fetch("sections_by_tone")
    <<~TEXT
      五音集韻 structural audit
      ========================
      Mode:                               ZERO-WRITE
      Parser:                             #{summary['parser_name']}
      Parser work status:                 #{summary['work_status']}
      Entries produced for review:        #{summary['entries']}
      Sections:                           #{summary['sections']} (expected 160)
        平聲:                              #{tones['平聲']} (expected 44)
        上聲:                              #{tones['上聲']} (expected 43)
        去聲:                              #{tones['去聲']} (expected 47)
        入聲:                              #{tones['入聲']} (expected 26)
      Pronunciation groups:               #{summary['pronunciation_groups']}
      Groups with reading marker:         #{summary['groups_with_pronunciation_marker']}
      Groups without reading marker:      #{summary['groups_without_pronunciation_marker']}
      Reading coverage:                   #{summary['reading_coverage_percent']}%
      Groups without declared count:      #{summary['groups_without_declared_count']}
      Declared group-count mismatches:     #{summary['declared_group_count_mismatches']}
      Structural headword contamination:  #{summary['structural_headword_contamination']}
      Entries without tone:               #{summary['entries_without_tone']}
      Parser warnings:                    #{summary['parser_warnings']}
      Unexpected parser warnings:         #{summary['unexpected_parser_warnings']}
      Unmatched payloads:                 #{summary['unmatched_payloads']}
      Unmatched head groups:              #{summary['unmatched_head_groups']}
      Structural blockers:                #{summary['structural_blockers']}
      Source-quality finding categories:  #{summary['source_quality_findings']}
      Ready to replace existing import:   #{summary['ready_to_replace_existing_import']}
      Recommended database action:        #{summary['recommended_database_action']}
      Corpus writes:                      0
      Database writes:                    0
    TEXT
  end

  def parse_options(argv)
    options = Options.new
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby script/audit_wuyin_jiyun_structure.rb --import-plan DIR [--output DIR]"
      opts.on("--import-plan DIR", "Dry-run import-plan directory") { |value| options.import_plan = value }
      opts.on("--output DIR", "Audit report directory") { |value| options.output = value }
    end
    parser.parse!(argv)
    abort parser.to_s unless options.import_plan
    options
  end
end

exit AuditWuyinJiyunStructure.run(ARGV) if $PROGRAM_NAME == __FILE__
