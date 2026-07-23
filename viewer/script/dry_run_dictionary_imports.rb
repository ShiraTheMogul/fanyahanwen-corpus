#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "dictionary_import/support"
require_relative "dictionary_import/parsers"

module DryRunDictionaryImports
  module_function

  Options = Struct.new(:bundle, :staging, :output, :config, keyword_init: true)

  PARSER_CLASSES = {
    "廣韻" => DictionaryImport::Parsers::Guangyun,
    "洪武正韻" => DictionaryImport::Parsers::Hongwu,
    "重修廣韻" => DictionaryImport::Parsers::ChongxiuGuangyun,
    "集韻" => DictionaryImport::Parsers::Jiyun,
    "五音集韻" => DictionaryImport::Parsers::WuyinJiyun,
    "玉篇" => DictionaryImport::Parsers::Yupian,
    "釋名" => DictionaryImport::Parsers::Shiming
  }.freeze

  PARSER_NAMES = {
    "廣韻" => "guangyun_declared_small_rime",
    "洪武正韻" => "hongwu_explicit_grouped_rime",
    "重修廣韻" => "chongxiu_guangyun_declared_small_rime",
    "集韻" => "jiyun_multi_head_group",
    "五音集韻" => "wuyin_jiyun_structural_v10",
    "玉篇" => "yupian_section_queue",
    "釋名" => "shiming_segment_probe"
  }.freeze

  READY_STAGING_STATUSES = %w[ready ready_with_repairs table_or_structure_review].freeze
  REVIEW_STAGING_STATUS = "table_or_structure_review"
  WORK_SUMMARY_HEADERS = %w[
    configured_title category work_id parser status documents usable_documents invalid_documents
    review_documents sections parsed_sections empty_detected_sections tone_headers rhyme_headers
    initial_headers payloads entries matched_payload_ratio observed_groups group_heads
    group_heads_without_fanqie group_heads_without_pronunciation_marker abbreviated_cut_markers
    declared_groups group_count_mismatches group_count_missing unmatched_payloads
    unmatched_head_groups continuation_payloads carryover_headwords_reassigned
    group_boundaries_without_head resolved_group_boundaries_without_head
    payloads_after_headless_group_boundary source_gap_entries multiple_group_separator_tails
    safe_multiple_separator_variant_reassignments unparsed_group_separator_segments
    orphan_carryover_headwords
    unresolved_group_boundaries_at_document_end candidate_segments low_confidence_segments
    unresolved_squares replacement_characters empty_definitions tone_missing_entries
    structural_headword_contamination max_line_length warning_count
    validation_notes
  ].freeze

  GROUP_REVIEW_HEADERS = %w[
    configured_title dictionary_work_id document_id source_file source_path section_sequence
    tone tone_section rhyme_number rhyme_label initial group_sequence small_rime_number
    group_head_record_count group_headword group_headwords fanqie pronunciation_marker_raw
    pronunciation_marker_type entry_record_count headword_count declared_group_size
    declared_count_match source_line_start source_line_end contains_unresolved_glyph
    requires_review review_reasons
  ].freeze

  SECTION_REVIEW_HEADERS = %w[
    configured_title dictionary_work_id document_id source_file source_path section_sequence
    tone tone_section rhyme_number rhyme_label initial entry_record_count headword_count
    group_count group_head_count groups_without_pronunciation_marker declared_group_count
    declared_group_mismatch_count source_line_start source_line_end contains_unresolved_glyph
    requires_review review_reasons
  ].freeze

  def run(argv)
    options = parse_options(argv)
    bundle = Pathname(options.bundle).expand_path
    staging = Pathname(options.staging || bundle.join("dry_run", "source_staging")).expand_path
    output = Pathname(options.output || bundle.join("dry_run", "import_plan")).expand_path
    config_path = Pathname(options.config || DictionaryImport::Support::DEFAULT_CONFIG).expand_path
    catalogue_path = bundle.join("catalogue.csv")
    documents_path = bundle.join("documents.csv")
    staged_path = staging.join("prepared_documents.csv")
    abort "Bundle catalogue.csv not found: #{catalogue_path}" unless catalogue_path.file?
    abort "Bundle documents.csv not found: #{documents_path}" unless documents_path.file?
    abort "Staging report not found: #{staged_path}" unless staged_path.file?

    # Loading the configuration is deliberate even though parser selection is
    # currently explicit below: it verifies that this dry run belongs to the
    # same named-source catalogue as the extractor.
    DictionaryImport::Support.load_config(config_path)
    catalogue = CSV.read(catalogue_path, headers: true).map(&:to_h)
    documents = CSV.read(documents_path, headers: true).map(&:to_h)
    staged = CSV.read(staged_path, headers: true).map(&:to_h)
    staged_by_id = staged.to_h { |row| [row["document_id"].to_s, row] }
    attach_staged_paths!(documents, staged_by_id, staging)
    documents.select! { |row| row["selected_subset_document"].to_s != "false" }
    docs_by_title = documents.group_by { |row| row["configured_title"] }

    FileUtils.rm_rf(output) if output.directory?
    FileUtils.mkdir_p(output.join("samples"))
    ready_entries = []
    reference_entries = []
    candidate_entries = []
    quarantined_entries = []
    source_gap_entries = []
    warning_rows = []
    work_rows = []
    group_rows = []
    section_rows = []
    started = Time.now

    puts "=" * 78
    puts "DICTIONARY IMPORT PLAN — DRY RUN"
    puts "=" * 78
    puts "Bundle:  #{bundle}"
    puts "Staging: #{staging}"
    puts "Works:   #{catalogue.length}"
    puts "Output:  #{output}"
    puts

    catalogue.each_with_index do |work, index|
      title = work.fetch("configured_title")
      rows = Array(docs_by_title[title]).sort_by { |row| row["document_sequence"].to_i }
      print format("[%3d/%3d] %-24s ", index + 1, catalogue.length, title)

      invalid_rows = rows.reject { |row| READY_STAGING_STATUSES.include?(row["staging_status"]) }
      review_rows = rows.select { |row| row["staging_status"] == REVIEW_STAGING_STATUS }
      parser_class = PARSER_CLASSES[title]
      unless parser_class
        status = invalid_rows.empty? ? "catalogued_probe_only" : "source_recovery_required"
        metrics = probe_only(rows)
        work_rows << work_row(work, status, "probe_only", metrics, invalid_rows, review_rows, [], 0)
        puts status
        next
      end

      parser_name = PARSER_NAMES.fetch(title)
      parser = parser_class.new(
        title: title,
        work_id: work["work_id"],
        category: work["category"],
        parser_name: parser_name
      )
      usable_rows = rows.select { |row| row["prepared_path"] && File.file?(row["prepared_path"]) }
      result = parser.parse(usable_rows)
      validation = validate(title, result.metrics, invalid_rows, review_rows, result.warnings)
      status = validation.fetch(:status)

      result.warnings.each do |warning|
        warning_rows << warning.merge("configured_title" => title)
      end

      final_entries = result.entries.map do |entry|
        entry.merge(
          "dry_run_status" => status,
          "validation_notes" => validation.fetch(:notes)
        )
      end
      localized_review_entries, clean_entries = final_entries.partition do |entry|
        entry["contains_source_gap"] == true || entry["parser_review_required"] == true
      end

      localized_review_entries.each do |entry|
        source_gap_entries << entry.merge("dry_run_status" => "localized_source_gap")
      end

      destination = case status
                    when "reference_control"
                      reference_entries
                    when "ready_for_import_review", "ready_with_localized_source_gaps"
                      ready_entries
                    when "candidate_parser_review", "segmentation_probe", "structure_probe"
                      candidate_entries
                    else
                      quarantined_entries
                    end
      routed_status = status == "ready_with_localized_source_gaps" ? "ready_for_import_review" : status
      clean_entries.each do |entry|
        destination << entry.merge("dry_run_status" => routed_status)
      end

      current_groups = build_group_review(title, result.entries)
      current_sections = build_section_review(title, result.entries, current_groups)
      group_rows.concat(current_groups)
      section_rows.concat(current_sections)

      work_rows << work_row(
        work,
        status,
        parser_name,
        result.metrics,
        invalid_rows,
        review_rows,
        validation.fetch(:notes),
        result.warnings.length
      )
      DictionaryImport::Support.write_json(
        output.join("samples", DictionaryImport::Support.portable_component(title) + ".json"),
        {
          "configured_title" => title,
          "status" => status,
          "parser" => parser_name,
          "validation_notes" => validation.fetch(:notes),
          "metrics" => result.metrics,
          "sample_entries" => result.entries.first(100),
          "sample_groups" => current_groups.first(100),
          "sample_sections" => current_sections.first(100),
          "sample_warnings" => result.warnings.first(100)
        }
      )
      puts "#{status} entries=#{result.entries.length} parsed_sections=#{result.metrics[:parsed_sections].to_i} payload_match=#{format('%.1f%%', result.metrics[:matched_payload_ratio].to_f * 100)}"
    rescue StandardError => error
      warning_rows << {
        "configured_title" => title,
        "document_id" => nil,
        "file" => nil,
        "line" => nil,
        "kind" => "work_error",
        "detail" => "#{error.class}: #{error.message}"
      }
      work_rows << work_row(
        work,
        "work_error",
        PARSER_NAMES[title] || "probe_only",
        {},
        [],
        [],
        ["#{error.class}: #{error.message}"],
        1
      )
      puts "ERROR #{error.class}"
    end

    DictionaryImport::Support.write_jsonl(output.join("entries.reference_control.jsonl"), reference_entries)
    DictionaryImport::Support.write_jsonl(output.join("entries.ready_for_import_review.jsonl"), ready_entries)
    DictionaryImport::Support.write_jsonl(output.join("entries.candidate_review.jsonl"), candidate_entries)
    DictionaryImport::Support.write_jsonl(output.join("entries.quarantined.jsonl"), quarantined_entries)
    DictionaryImport::Support.write_jsonl(output.join("entries.localized_source_gaps.jsonl"), source_gap_entries)
    DictionaryImport::Support.write_csv(
      output.join("source_gaps.csv"),
      %w[configured_title dictionary_work_id document_id source_file source_path source_line_start source_line_end tone rhyme_label headword_status fanqie payload_raw parser_review_reasons],
      source_gap_entries.map do |entry|
        {
          "configured_title" => entry["dictionary_title"],
          "dictionary_work_id" => entry["dictionary_work_id"],
          "document_id" => entry["document_id"],
          "source_file" => entry["source_file"],
          "source_path" => entry["source_path"],
          "source_line_start" => entry["source_line_start"],
          "source_line_end" => entry["source_line_end"],
          "tone" => entry["tone"],
          "rhyme_label" => entry["rhyme_label"],
          "headword_status" => entry["headword_status"],
          "fanqie" => entry["fanqie"],
          "payload_raw" => entry["payload_raw"],
          "parser_review_reasons" => Array(entry["parser_review_reasons"]).join(";")
        }
      end
    )
    DictionaryImport::Support.write_csv(output.join("work_summary.csv"), WORK_SUMMARY_HEADERS, work_rows)
    DictionaryImport::Support.write_csv(output.join("groups.review.csv"), GROUP_REVIEW_HEADERS, group_rows)
    DictionaryImport::Support.write_csv(output.join("sections.review.csv"), SECTION_REVIEW_HEADERS, section_rows)
    DictionaryImport::Support.write_csv(
      output.join("warnings.csv"),
      %w[configured_title document_id file line kind detail],
      warning_rows
    )
    DictionaryImport::Support.atomic_write(output.join("IMPORT_CONTRACT.md"), import_contract)

    status_counts = work_rows.each_with_object(Hash.new(0)) { |row, out| out[row["status"]] += 1 }
    summary = {
      "version" => 5,
      "mode" => "dry_run",
      "created_at" => Time.now.utc.iso8601,
      "elapsed_seconds" => (Time.now - started).round(3),
      "bundle" => bundle.to_s,
      "staging" => staging.to_s,
      "works" => catalogue.length,
      "status_counts" => status_counts,
      "reference_control_entries" => reference_entries.length,
      "ready_for_import_review_entries" => ready_entries.length,
      "candidate_review_entries" => candidate_entries.length,
      "quarantined_entries" => quarantined_entries.length,
      "localized_source_gap_entries" => source_gap_entries.length,
      "group_review_rows" => group_rows.length,
      "group_review_required" => group_rows.count { |row| row["requires_review"] == true },
      "section_review_rows" => section_rows.length,
      "section_review_required" => section_rows.count { |row| row["requires_review"] == true },
      "warnings" => warning_rows.length,
      "corpus_writes" => 0,
      "database_writes" => 0
    }
    DictionaryImport::Support.write_json(output.join("summary.json"), summary)
    DictionaryImport::Support.atomic_write(output.join("summary.txt"), summary_text(summary))

    puts
    puts summary_text(summary)
    puts "Reports: #{output}"
    0
  end

  def attach_staged_paths!(documents, staged_by_id, staging)
    documents.each do |row|
      stage = staged_by_id[row["document_id"].to_s]
      next unless stage

      row["staging_status"] = stage["status"]
      row["staging_reasons"] = stage["reason_codes"]
      prepared = stage["prepared_relative_path"].to_s
      line_map = stage["line_map_relative_path"].to_s
      row["prepared_path"] = staging.join(prepared).to_s unless prepared.empty?
      row["line_map_path"] = staging.join(line_map).to_s unless line_map.empty?
    end
  end

  def validate(title, metrics, invalid_rows, review_rows, warnings)
    blockers = []
    notes = []
    notes << "invalid_or_missing_documents=#{invalid_rows.length}" if invalid_rows.any?
    notes << "structure_review_documents=#{review_rows.length}" if review_rows.any?
    entries = metrics[:entries].to_i
    ratio = metrics[:matched_payload_ratio].to_f
    warning_counts = Array(warnings).each_with_object(Hash.new(0)) do |warning, out|
      out[warning["kind"].to_s] += 1
    end

    case title
    when "廣韻"
      blockers << "fewer_than_20000_entries" if entries < 20_000
      blockers << "payload_match_below_95_percent" if ratio < 0.95
      blockers << "invalid_source_documents" if invalid_rows.any?
      notes << "reference_control_only_already_imported"
      append_structural_notes(notes, metrics, warning_counts)
      status = blockers.empty? ? "reference_control" : "parser_or_source_review"
    when "洪武正韻"
      blockers << "fewer_than_10000_entries" if entries < 10_000
      blockers << "payload_match_below_99_percent" if ratio < 0.99
      blockers << "fewer_than_70_parsed_sections" if metrics[:parsed_sections].to_i < 70
      blockers << "unmatched_payloads=#{metrics[:unmatched_payloads]}" if metrics[:unmatched_payloads].to_i.positive?
      blockers << "unmatched_head_groups=#{metrics[:unmatched_head_groups]}" if metrics[:unmatched_head_groups].to_i.positive?
      blockers << "replacement_characters=#{metrics[:replacement_characters]}" if metrics[:replacement_characters].to_i.positive?
      blockers << "invalid_source_documents" if invalid_rows.any?
      blockers << "structure_review_documents" if review_rows.any?
      blockers << "no_group_heads" if metrics[:group_heads].to_i.zero?
      localized_gap_count = metrics[:source_gap_entries].to_i
      blockers << "multiple_group_separator_tails=#{metrics[:multiple_group_separator_tails]}" if metrics[:multiple_group_separator_tails].to_i.positive?
      blockers << "unparsed_group_separator_segments=#{metrics[:unparsed_group_separator_segments]}" if metrics[:unparsed_group_separator_segments].to_i.positive?
      blockers << "unresolved_group_boundaries_at_document_end=#{metrics[:unresolved_group_boundaries_at_document_end]}" if metrics[:unresolved_group_boundaries_at_document_end].to_i.positive?

      localized_warning_count = warning_counts["payload_after_group_separator_without_head"].to_i
      other_structural_warning_total = warning_counts.values_at(
        "payload_without_head",
        "head_group_replaced",
        "final_unmatched_head_group",
        "multiple_group_separators_in_tail",
        "unparsed_group_separator_segment",
        "orphan_carryover_headwords",
        "unresolved_group_boundary_at_document_end",
        "work_error"
      ).compact.sum
      blockers << "structural_warnings=#{other_structural_warning_total}" if other_structural_warning_total.positive?
      if localized_warning_count != localized_gap_count
        blockers << "localized_gap_warning_mismatch=#{localized_warning_count}:#{localized_gap_count}"
      end

      notes << "source_gap_entries=#{localized_gap_count}" if localized_gap_count.positive?
      notes << "localized_structural_warnings=#{localized_warning_count}" if localized_warning_count.positive?
      notes << "group_heads_without_pronunciation_marker=#{metrics[:group_heads_without_pronunciation_marker]}" if metrics[:group_heads_without_pronunciation_marker].to_i.positive?
      notes << "abbreviated_cut_markers=#{metrics[:abbreviated_cut_markers]}" if metrics[:abbreviated_cut_markers].to_i.positive?
      notes << "empty_definitions=#{metrics[:empty_definitions]}" if metrics[:empty_definitions].to_i.positive?
      status = if blockers.any?
                 "parser_or_source_review"
               elsif localized_gap_count.positive?
                 "ready_with_localized_source_gaps"
               else
                 "ready_for_import_review"
               end
    when "五音集韻"
      # Parser v10 separates structural validity from source-quality evidence.
      #
      # Structural blockers mean the parser has not understood the work safely.
      # Source findings mean the work is readable, but the Wikisource scrape has
      # an omitted fanqie or a damaged/missing group-count suffix. Those findings
      # remain in warnings.csv and the group/section review files; they do not
      # collapse the entire dictionary back into quarantine.
      blockers << "fewer_than_45000_entries" if entries < 45_000
      blockers << "payload_match_below_99_percent" if ratio < 0.99
      blockers << "parsed_sections_not_160=#{metrics[:parsed_sections]}" unless metrics[:parsed_sections].to_i == 160
      blockers << "fewer_than_3500_pronunciation_groups=#{metrics[:observed_groups]}" if metrics[:observed_groups].to_i < 3_500
      if metrics[:group_heads].to_i != metrics[:observed_groups].to_i
        blockers << "group_head_count_mismatch=#{metrics[:group_heads]}:#{metrics[:observed_groups]}"
      end
      blockers << "structural_headword_contamination=#{metrics[:structural_headword_contamination]}" if metrics[:structural_headword_contamination].to_i.positive?
      blockers << "entries_without_tone=#{metrics[:tone_missing_entries]}" if metrics[:tone_missing_entries].to_i.positive?
      blockers << "unmatched_payloads=#{metrics[:unmatched_payloads]}" if metrics[:unmatched_payloads].to_i.positive?
      blockers << "source_gap_entries=#{metrics[:source_gap_entries]}" if metrics[:source_gap_entries].to_i.positive?
      blockers << "replacement_characters=#{metrics[:replacement_characters]}" if metrics[:replacement_characters].to_i.positive?
      blockers << "invalid_source_documents" if invalid_rows.any?

      source_warning_kinds = %w[
        group_head_without_declared_count
        declared_group_count_mismatch
        head_group_replaced
      ]
      unexpected_warning_total = warning_counts.sum do |kind, count|
        source_warning_kinds.include?(kind) ? 0 : count.to_i
      end
      blockers << "unexpected_parser_warnings=#{unexpected_warning_total}" if unexpected_warning_total.positive?

      append_structural_notes(notes, metrics, warning_counts)
      notes << "source_finding_groups_without_pronunciation_marker=#{metrics[:group_heads_without_pronunciation_marker]}" if metrics[:group_heads_without_pronunciation_marker].to_i.positive?
      notes << "source_finding_groups_without_declared_count=#{metrics[:group_count_missing]}" if metrics[:group_count_missing].to_i.positive?
      notes << "source_finding_declared_group_count_mismatches=#{metrics[:group_count_mismatches]}" if metrics[:group_count_mismatches].to_i.positive?
      notes << "source_finding_unmatched_head_groups=#{metrics[:unmatched_head_groups]}" if metrics[:unmatched_head_groups].to_i.positive?
      notes << "tone_derived_from_volume_sequence"
      notes << "division_and_initial_headers_excluded_from_headwords"
      notes << "fanqie_led_payloads_start_pronunciation_groups"
      notes << "damaged_group_counts_reported_not_silently_repaired"
      status = blockers.any? ? "parser_or_source_review" : "ready_for_import_review"
    when "重修廣韻", "集韻"
      blockers << "fewer_than_1000_entries" if entries < 1_000
      notes << "parser_development_source"
      append_structural_notes(notes, metrics, warning_counts)
      status = if invalid_rows.any? || blockers.any?
                 "parser_or_source_review"
               else
                 "candidate_parser_review"
               end
    when "玉篇"
      notes << "section_queue_requires_span_review"
      append_structural_notes(notes, metrics, warning_counts)
      status = invalid_rows.empty? ? "structure_probe" : "parser_or_source_review"
    when "釋名"
      notes << "semantic_segments_are_candidates_not_senses"
      status = invalid_rows.empty? ? "segmentation_probe" : "parser_or_source_review"
    else
      status = "catalogued_probe_only"
    end

    { status: status, notes: (blockers + notes).uniq }
  end

  def append_structural_notes(notes, metrics, warning_counts)
    {
      "parsed_sections" => metrics[:parsed_sections],
      "empty_detected_sections" => metrics[:empty_detected_sections],
      "group_count_mismatches" => metrics[:group_count_mismatches],
      "group_count_missing" => metrics[:group_count_missing],
      "unmatched_payloads" => metrics[:unmatched_payloads],
      "unmatched_head_groups" => metrics[:unmatched_head_groups],
      "carryover_headwords_reassigned" => metrics[:carryover_headwords_reassigned],
      "group_boundaries_without_head" => metrics[:group_boundaries_without_head],
      "resolved_group_boundaries_without_head" => metrics[:resolved_group_boundaries_without_head],
      "payloads_after_headless_group_boundary" => metrics[:payloads_after_headless_group_boundary],
      "source_gap_entries" => metrics[:source_gap_entries],
      "multiple_group_separator_tails" => metrics[:multiple_group_separator_tails],
      "safe_multiple_separator_variant_reassignments" => metrics[:safe_multiple_separator_variant_reassignments],
      "unparsed_group_separator_segments" => metrics[:unparsed_group_separator_segments],
      "orphan_carryover_headwords" => metrics[:orphan_carryover_headwords],
      "unresolved_group_boundaries_at_document_end" => metrics[:unresolved_group_boundaries_at_document_end],
      "tone_missing_entries" => metrics[:tone_missing_entries],
      "structural_headword_contamination" => metrics[:structural_headword_contamination]
    }.each do |name, value|
      notes << "#{name}=#{value.to_i}" if value.to_i.positive?
    end
    warning_counts.each do |kind, count|
      notes << "warning_#{kind}=#{count}" if count.positive?
    end
  end

  def probe_only(rows)
    metrics = Hash.new(0)
    rows.each do |row|
      next unless row["prepared_path"] && File.file?(row["prepared_path"])

      text = DictionaryImport::Support.read_utf8(row["prepared_path"])
      metrics[:documents] += 1
      metrics[:usable_documents] += 1
      metrics[:payloads] += text.count("〈")
      metrics[:unresolved_squares] += text.count("□")
      metrics[:replacement_characters] += text.count("\uFFFD")
      metrics[:max_line_length] = [metrics[:max_line_length], text.lines.map { |line| line.chomp.length }.max.to_i].max
    end
    metrics
  end

  def build_group_review(title, entries)
    grouped = Array(entries).select do |entry|
      entry["section_sequence"].to_i.positive? && entry["group_sequence"].to_i.positive?
    end.group_by do |entry|
      [entry["document_id"].to_s, entry["section_sequence"].to_i, entry["group_sequence"].to_i]
    end

    grouped.values.map do |rows|
      sorted = rows.sort_by { |row| row["sequence_number"].to_i }
      heads = sorted.select { |row| row["is_group_head"] }
      head = heads.first || sorted.first
      declared_values = sorted.filter_map do |row|
        value = row["declared_group_size"]
        value.to_i if !value.nil? && value.to_s != ""
      end.uniq
      declared = declared_values.length == 1 ? declared_values.first : nil
      headword_count = sorted.sum { |row| Array(row["headwords"]).length }
      reasons = []
      reasons << "group_head_record_count=#{heads.length}" unless heads.length == 1
      reasons << "multiple_declared_group_sizes=#{declared_values.join('|')}" if declared_values.length > 1
      reasons << "declared_count_mismatch=#{declared}:#{headword_count}" if declared && declared != headword_count
      reasons << "group_head_missing" if head.nil?
      reasons << "group_headword_missing" if head && head["headword"].to_s.empty?
      parser_review_rows = sorted.select { |row| row["parser_review_required"] == true }
      if parser_review_rows.any?
        parser_reasons = parser_review_rows.flat_map { |row| Array(row["parser_review_reasons"]) }.uniq
        reasons << "parser_review=#{parser_reasons.join('|')}"
      end

      {
        "configured_title" => title,
        "dictionary_work_id" => head && head["dictionary_work_id"],
        "document_id" => head && head["document_id"],
        "source_file" => head && head["source_file"],
        "source_path" => head && head["source_path"],
        "section_sequence" => head && head["section_sequence"],
        "tone" => head && head["tone"],
        "tone_section" => head && head["tone_section"],
        "rhyme_number" => head && head["rhyme_number"],
        "rhyme_label" => head && head["rhyme_label"],
        "initial" => head && head["initial"],
        "group_sequence" => head && head["group_sequence"],
        "small_rime_number" => head && head["small_rime_number"],
        "group_head_record_count" => heads.length,
        "group_headword" => head && head["headword"],
        "group_headwords" => head ? Array(head["headwords"]).join : nil,
        "fanqie" => head && head["fanqie"],
        "pronunciation_marker_raw" => head && head["pronunciation_marker_raw"],
        "pronunciation_marker_type" => head && head["pronunciation_marker_type"],
        "entry_record_count" => sorted.length,
        "headword_count" => headword_count,
        "declared_group_size" => declared,
        "declared_count_match" => declared.nil? ? nil : declared == headword_count,
        "source_line_start" => sorted.map { |row| row["source_line_start"].to_i }.min,
        "source_line_end" => sorted.map { |row| row["source_line_end"].to_i }.max,
        "contains_unresolved_glyph" => sorted.any? { |row| row["contains_unresolved_glyph"] },
        "requires_review" => reasons.any?,
        "review_reasons" => reasons.join(";")
      }
    end.sort_by do |row|
      [row["configured_title"].to_s, row["document_id"].to_s, row["section_sequence"].to_i, row["group_sequence"].to_i]
    end
  end

  def build_section_review(title, entries, groups)
    group_by_section = groups.group_by { |row| [row["document_id"].to_s, row["section_sequence"].to_i] }
    grouped = Array(entries).select { |entry| entry["section_sequence"].to_i.positive? }.group_by do |entry|
      [entry["document_id"].to_s, entry["section_sequence"].to_i]
    end

    grouped.values.map do |rows|
      sorted = rows.sort_by { |row| row["sequence_number"].to_i }
      first = sorted.first
      section_groups = Array(group_by_section[[first["document_id"].to_s, first["section_sequence"].to_i]])
      reasons = []
      reasons << "no_groups" if section_groups.empty? && title != "釋名"
      review_group_count = section_groups.count { |row| row["requires_review"] == true }
      reasons << "groups_requiring_review=#{review_group_count}" if review_group_count.positive?

      {
        "configured_title" => title,
        "dictionary_work_id" => first["dictionary_work_id"],
        "document_id" => first["document_id"],
        "source_file" => first["source_file"],
        "source_path" => first["source_path"],
        "section_sequence" => first["section_sequence"],
        "tone" => first["tone"],
        "tone_section" => first["tone_section"],
        "rhyme_number" => first["rhyme_number"],
        "rhyme_label" => first["rhyme_label"],
        "initial" => first["initial"],
        "entry_record_count" => sorted.length,
        "headword_count" => sorted.sum { |row| Array(row["headwords"]).length },
        "group_count" => section_groups.length,
        "group_head_count" => section_groups.sum { |row| row["group_head_record_count"].to_i },
        "groups_without_pronunciation_marker" => section_groups.count { |row| row["pronunciation_marker_raw"].to_s.empty? },
        "declared_group_count" => section_groups.count { |row| !row["declared_group_size"].nil? },
        "declared_group_mismatch_count" => section_groups.count { |row| row["declared_count_match"] == false },
        "source_line_start" => sorted.map { |row| row["source_line_start"].to_i }.min,
        "source_line_end" => sorted.map { |row| row["source_line_end"].to_i }.max,
        "contains_unresolved_glyph" => sorted.any? { |row| row["contains_unresolved_glyph"] },
        "requires_review" => reasons.any?,
        "review_reasons" => reasons.join(";")
      }
    end.sort_by do |row|
      [row["configured_title"].to_s, row["document_id"].to_s, row["section_sequence"].to_i]
    end
  end

  def work_row(work, status, parser, metrics, invalid_rows, review_rows, notes, warning_count)
    {
      "configured_title" => work["configured_title"],
      "category" => work["category"],
      "work_id" => work["work_id"],
      "parser" => parser,
      "status" => status,
      "documents" => work["document_count"].to_i,
      "usable_documents" => metrics[:documents].to_i,
      "invalid_documents" => invalid_rows.length,
      "review_documents" => review_rows.length,
      "sections" => metrics[:sections].to_i,
      "parsed_sections" => metrics[:parsed_sections].to_i,
      "empty_detected_sections" => metrics[:empty_detected_sections].to_i,
      "tone_headers" => metrics[:tone_headers].to_i,
      "rhyme_headers" => metrics[:rhyme_headers].to_i,
      "initial_headers" => metrics[:initial_headers].to_i,
      "payloads" => metrics[:payloads].to_i,
      "entries" => metrics[:entries].to_i,
      "matched_payload_ratio" => format("%.5f", metrics[:matched_payload_ratio].to_f),
      "observed_groups" => metrics[:observed_groups].to_i,
      "group_heads" => metrics[:group_heads].to_i,
      "group_heads_without_fanqie" => metrics[:group_heads_without_fanqie].to_i,
      "group_heads_without_pronunciation_marker" => metrics[:group_heads_without_pronunciation_marker].to_i,
      "abbreviated_cut_markers" => metrics[:abbreviated_cut_markers].to_i,
      "declared_groups" => metrics[:declared_groups].to_i,
      "group_count_mismatches" => metrics[:group_count_mismatches].to_i,
      "group_count_missing" => metrics[:group_count_missing].to_i,
      "unmatched_payloads" => metrics[:unmatched_payloads].to_i,
      "unmatched_head_groups" => metrics[:unmatched_head_groups].to_i,
      "continuation_payloads" => metrics[:continuation_payloads].to_i,
      "carryover_headwords_reassigned" => metrics[:carryover_headwords_reassigned].to_i,
      "group_boundaries_without_head" => metrics[:group_boundaries_without_head].to_i,
      "resolved_group_boundaries_without_head" => metrics[:resolved_group_boundaries_without_head].to_i,
      "payloads_after_headless_group_boundary" => metrics[:payloads_after_headless_group_boundary].to_i,
      "source_gap_entries" => metrics[:source_gap_entries].to_i,
      "multiple_group_separator_tails" => metrics[:multiple_group_separator_tails].to_i,
      "safe_multiple_separator_variant_reassignments" => metrics[:safe_multiple_separator_variant_reassignments].to_i,
      "unparsed_group_separator_segments" => metrics[:unparsed_group_separator_segments].to_i,
      "orphan_carryover_headwords" => metrics[:orphan_carryover_headwords].to_i,
      "unresolved_group_boundaries_at_document_end" => metrics[:unresolved_group_boundaries_at_document_end].to_i,
      "candidate_segments" => metrics[:candidate_segments].to_i,
      "low_confidence_segments" => metrics[:low_confidence_segments].to_i,
      "unresolved_squares" => metrics[:unresolved_squares].to_i,
      "replacement_characters" => metrics[:replacement_characters].to_i,
      "empty_definitions" => metrics[:empty_definitions].to_i,
      "tone_missing_entries" => metrics[:tone_missing_entries].to_i,
      "structural_headword_contamination" => metrics[:structural_headword_contamination].to_i,
      "max_line_length" => metrics[:max_line_length].to_i,
      "warning_count" => warning_count.to_i,
      "validation_notes" => Array(notes).join(";")
    }
  end

  def summary_text(summary)
    counts = summary.fetch("status_counts")
    <<~TEXT
      Dictionary import dry run complete
      ==================================
      Works:                           #{summary['works']}
      Guangyun reference-control:      #{counts['reference_control'].to_i}
      Ready for import review:         #{counts['ready_for_import_review'].to_i}
      Ready with localized gaps:       #{counts['ready_with_localized_source_gaps'].to_i}
      Candidate parser review:         #{counts['candidate_parser_review'].to_i}
      Structure probes:                #{counts['structure_probe'].to_i}
      Segmentation probes:             #{counts['segmentation_probe'].to_i}
      Probe-only/catalogued:            #{counts['catalogued_probe_only'].to_i}
      Source recovery required:         #{counts['source_recovery_required'].to_i}
      Parser/source review:             #{counts['parser_or_source_review'].to_i}
      Work errors:                      #{counts['work_error'].to_i}
      Reference-control entries:        #{summary['reference_control_entries']}
      Ready-for-import-review entries:  #{summary['ready_for_import_review_entries']}
      Candidate-review entries:         #{summary['candidate_review_entries']}
      Quarantined entries:              #{summary['quarantined_entries']}
      Localized source-gap entries:     #{summary['localized_source_gap_entries']}
      Group review rows:                #{summary['group_review_rows']}
      Groups requiring review:          #{summary['group_review_required']}
      Section review rows:              #{summary['section_review_rows']}
      Sections requiring review:        #{summary['section_review_required']}
      Warnings:                         #{summary['warnings']}
      Corpus writes:                    0
      Database writes:                  0
      Elapsed seconds:                  #{summary['elapsed_seconds']}
    TEXT
  end

  def import_contract
    <<~MARKDOWN
      # Dictionary import dry-run contract

      This output does not write to the corpus, Rails, SQLite, routes, or the
      already-imported 廣韻 data.

      The extracted corpus TXT and metadata files are the sole textual source for
      this import plan. The dry run does not consult, merge, or propose readings
      from external websites or editions. Missing or damaged source text remains
      explicitly missing or quarantined.

      `entries.reference_control.jsonl` is a newly parsed 廣韻 comparison set.
      It is diagnostic only. The source contains some damaged or interleaved
      spans, and the existing 廣韻 import is not replaced by this file.

      `entries.ready_for_import_review.jsonl` contains clean rows from sources
      whose source-specific parser passed the current strict structural
      thresholds. A work may still have a small number of separately isolated
      source gaps. A row in this file is a review candidate, not an automatic
      database write.

      `entries.localized_source_gaps.jsonl` and `source_gaps.csv` isolate rows
      whose headword is absent from the transcription or whose source structure
      remains ambiguous. These rows are not duplicated in the ready, candidate,
      reference-control, or quarantined JSONL files.

      `entries.candidate_review.jsonl` preserves parser-development output for
      重修廣韻、集韻、五音集韻、玉篇、釋名. These rows are evidence and samples,
      not approved dictionary records.

      `groups.review.csv` summarizes each parsed group or small-rime unit.
      `sections.review.csv` summarizes each parsed rhyme/section. They exist so
      entry counts cannot conceal a broken grouping model.

      Fanqie is populated only from an exact two-Han-character + 切 prefix at a
      group head. One-character + 切 abbreviations are preserved separately as
      `pronunciation_marker_type=abbreviated_cut`. Later 又…切 phrases remain in
      the definition.

      Every entry keeps source work/document IDs, paths, source line ranges,
      sequence, raw payload or segment, unresolved-glyph flags, parser name and
      parser version. A later Rails importer must use normalized dictionary
      work/section/entry/reading records rather than adding more
      source-specific CharacterProperty columns.
    MARKDOWN
  end

  def parse_options(argv)
    options = Options.new
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby script/dry_run_dictionary_imports.rb --bundle PATH [options]"
      opts.on("--bundle PATH", "Extracted source bundle") { |value| options.bundle = value }
      opts.on("--staging PATH", "Staging output directory") { |value| options.staging = value }
      opts.on("--output PATH", "Import-plan output directory") { |value| options.output = value }
      opts.on("--config PATH", "Named-source catalogue YAML") { |value| options.config = value }
      opts.on("-h", "--help", "Show help") { puts opts; exit 0 }
    end
    parser.parse!(argv)
    abort parser.to_s unless options.bundle
    abort "Unexpected arguments: #{argv.join(' ')}" unless argv.empty?
    options
  end
end

exit DryRunDictionaryImports.run(ARGV)
