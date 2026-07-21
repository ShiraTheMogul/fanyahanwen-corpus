#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "dictionary_import_support"

module PrepareDictionarySources
  module_function

  Options = Struct.new(:snapshot, :output, keyword_init: true)
  DOCUMENT_HEADERS = %w[canonical_title metadata_title category work_id document_sequence document_id file source_relative_path snapshot_relative_path bytes sha256 page_title display_title body_start_line].freeze

  def run(argv)
    options = parse_options(argv)
    snapshot = Pathname(options.snapshot).expand_path
    output = Pathname(options.output || snapshot.join("dry_runs", "source_preparation")).expand_path
    docs_csv = snapshot.join("documents.csv")
    abort "Snapshot documents.csv not found: #{docs_csv}" unless docs_csv.file?

    documents = CSV.read(docs_csv, headers: true).map(&:to_h)
    FileUtils.mkdir_p(output)
    prepared_root = output.join("prepared")
    started = Time.now
    document_rows = []
    action_rows = []
    quarantine_rows = []
    work_stats = Hash.new { |hash, key| hash[key] = Hash.new(0) }

    puts "=" * 76
    puts "DICTIONARY SOURCE PREPARATION — DRY RUN"
    puts "=" * 76
    puts "Snapshot:  #{snapshot}"
    puts "Documents: #{documents.length}"
    puts "Output:    #{output}"
    puts

    documents.each_with_index do |row, index|
      source = snapshot.join(row.fetch("snapshot_relative_path"))
      title = row.fetch("canonical_title")
      print format("[%5d/%5d] %-24s %-24s ", index + 1, documents.length, title, row.fetch("file"))

      begin
        text = DictionaryImportSupport.safe_read_text(source)
        prepared, metrics, actions = prepare_text(text)
        status, reasons = classify(metrics)
        target = prepared_root.join(row.fetch("source_relative_path"))
        DictionaryImportSupport.atomic_write(target, prepared)

        document_rows << row.merge(
          "prepared_relative_path" => DictionaryImportSupport.relative(target, output),
          "prepared_sha256" => DictionaryImportSupport.sha256(target),
          "status" => status,
          "reason_codes" => reasons.join(";"),
          "original_bytes" => text.bytesize,
          "prepared_bytes" => prepared.bytesize,
          "bom_removed" => metrics.fetch(:bom_removed),
          "newline_normalized" => metrics.fetch(:newline_normalized),
          "trailing_whitespace_lines" => metrics.fetch(:trailing_whitespace_lines),
          "joined_bracket_linebreaks" => metrics.fetch(:joined_bracket_linebreaks),
          "angle_open_count" => metrics.fetch(:angle_open_count),
          "angle_close_count" => metrics.fetch(:angle_close_count),
          "placeholder_count" => metrics.fetch(:placeholder_count),
          "replacement_character_count" => metrics.fetch(:replacement_character_count),
          "max_line_length" => metrics.fetch(:max_line_length),
          "flattened_line_count" => metrics.fetch(:flattened_line_count)
        )
        actions.each do |action, count|
          next if count.to_i.zero?
          action_rows << {
            "canonical_title" => title,
            "document_id" => row["document_id"],
            "file" => row["file"],
            "action" => action,
            "count" => count
          }
        end
        reasons.each do |reason|
          quarantine_rows << {
            "canonical_title" => title,
            "document_id" => row["document_id"],
            "file" => row["file"],
            "status" => status,
            "reason" => reason,
            "source_relative_path" => row["source_relative_path"]
          }
        end
        work_stats[title][status] += 1
        work_stats[title]["documents"] += 1
        work_stats[title]["joined_bracket_linebreaks"] += metrics.fetch(:joined_bracket_linebreaks)
        puts "#{status}#{reasons.empty? ? '' : " (#{reasons.join(',')})"}"
      rescue StandardError => error
        status = "quarantined"
        document_rows << row.merge(
          "prepared_relative_path" => nil,
          "status" => status,
          "reason_codes" => "read_or_prepare_error"
        )
        quarantine_rows << {
          "canonical_title" => title,
          "document_id" => row["document_id"],
          "file" => row["file"],
          "status" => status,
          "reason" => "#{error.class}: #{error.message}",
          "source_relative_path" => row["source_relative_path"]
        }
        work_stats[title][status] += 1
        work_stats[title]["documents"] += 1
        puts "ERROR #{error.class}"
      end
    end

    work_rows = work_stats.keys.sort.map do |title|
      stats = work_stats.fetch(title)
      {
        "canonical_title" => title,
        "documents" => stats["documents"],
        "ready_as_is" => stats["ready_as_is"],
        "prepared_safe" => stats["prepared_safe"],
        "needs_structure_review" => stats["needs_structure_review"],
        "requires_source_recovery" => stats["requires_source_recovery"],
        "quarantined" => stats["quarantined"],
        "joined_bracket_linebreaks" => stats["joined_bracket_linebreaks"]
      }
    end

    doc_headers = DOCUMENT_HEADERS + %w[prepared_relative_path prepared_sha256 status reason_codes original_bytes prepared_bytes bom_removed newline_normalized trailing_whitespace_lines joined_bracket_linebreaks angle_open_count angle_close_count placeholder_count replacement_character_count max_line_length flattened_line_count]
    DictionaryImportSupport.write_csv(output.join("prepared_documents.csv"), doc_headers, document_rows)
    DictionaryImportSupport.write_csv(output.join("repair_actions.csv"), %w[canonical_title document_id file action count], action_rows)
    DictionaryImportSupport.write_csv(output.join("quarantine.csv"), %w[canonical_title document_id file status reason source_relative_path], quarantine_rows)
    DictionaryImportSupport.write_csv(output.join("work_summary.csv"), %w[canonical_title documents ready_as_is prepared_safe needs_structure_review requires_source_recovery quarantined joined_bracket_linebreaks], work_rows)

    counts = document_rows.each_with_object(Hash.new(0)) { |row, tally| tally[row["status"]] += 1 }
    summary = {
      "version" => 1,
      "mode" => "dry_run",
      "created_at" => Time.now.utc.iso8601,
      "elapsed_seconds" => (Time.now - started).round(3),
      "snapshot" => snapshot.to_s,
      "documents" => documents.length,
      "status_counts" => counts,
      "repair_action_count" => action_rows.sum { |row| row["count"].to_i },
      "review_rows" => quarantine_rows.length,
      "prepared_root" => prepared_root.to_s
    }
    DictionaryImportSupport.write_json(output.join("summary.json"), summary)
    DictionaryImportSupport.atomic_write(output.join("summary.txt"), summary_text(summary))

    puts
    puts summary_text(summary)
    puts "Reports: #{output}"
    0
  end

  def prepare_text(text)
    metrics = {
      bom_removed: 0,
      newline_normalized: 0,
      trailing_whitespace_lines: 0,
      joined_bracket_linebreaks: 0,
      angle_open_count: 0,
      angle_close_count: 0,
      placeholder_count: 0,
      replacement_character_count: text.count("\uFFFD"),
      max_line_length: 0,
      flattened_line_count: 0,
      negative_angle_depth: false,
      final_angle_depth: 0
    }

    normalized = text.dup
    bom_index = normalized.index("\uFEFF")
    if bom_index && normalized[0...bom_index].match?(/\A[\s]*\z/)
      normalized.slice!(bom_index)
      metrics[:bom_removed] = 1
    end

    crlf = normalized.scan(/\r\n/).length
    lone_cr = normalized.scan(/\r(?!\n)/).length
    metrics[:newline_normalized] = crlf + lone_cr
    normalized = normalized.gsub("\r\n", "\n").tr("\r", "\n")

    lines = normalized.split("\n", -1)
    lines.map! do |line|
      stripped = line.rstrip
      metrics[:trailing_whitespace_lines] += 1 if stripped != line
      stripped
    end
    normalized = lines.join("\n")

    prepared = +""
    depth = 0
    normalized.each_char do |char|
      case char
      when "〈"
        metrics[:angle_open_count] += 1
        depth += 1
        prepared << char
      when "〉"
        metrics[:angle_close_count] += 1
        depth -= 1
        metrics[:negative_angle_depth] = true if depth.negative?
        prepared << char
      when "\n"
        if depth.positive?
          metrics[:joined_bracket_linebreaks] += 1
        else
          prepared << char
        end
      else
        prepared << char
      end
    end
    metrics[:final_angle_depth] = depth
    prepared << "\n" unless prepared.end_with?("\n")

    logical_lines = prepared.lines.map { |line| line.chomp("\n") }
    metrics[:placeholder_count] = logical_lines.count { |line| line.match?(/\A\s*<經部,[^>]+>\s*\z/) }
    lengths = logical_lines.map(&:length)
    metrics[:max_line_length] = lengths.max.to_i
    metrics[:flattened_line_count] = logical_lines.count do |line|
      line.length > 800 && (line.count("〈") + line.count("〉")) >= 8
    end

    actions = {
      "remove_bom" => metrics[:bom_removed],
      "normalize_newlines" => metrics[:newline_normalized],
      "remove_trailing_whitespace" => metrics[:trailing_whitespace_lines],
      "join_bracket_payload_linebreaks" => metrics[:joined_bracket_linebreaks],
      "ensure_final_newline" => text.end_with?("\n") ? 0 : 1
    }
    [prepared, metrics, actions]
  end

  def classify(metrics)
    reasons = []
    reasons << "replacement_character" if metrics[:replacement_character_count].positive?
    reasons << "unbalanced_angle_brackets" if metrics[:negative_angle_depth] || !metrics[:final_angle_depth].zero?
    return ["quarantined", reasons] if reasons.any?

    if metrics[:placeholder_count] >= 3
      reasons << "source_template_placeholders"
      return ["requires_source_recovery", reasons]
    end

    if metrics[:flattened_line_count].positive?
      reasons << "flattened_multi_entry_lines"
      return ["needs_structure_review", reasons]
    end

    changed = metrics.values_at(:bom_removed, :newline_normalized, :trailing_whitespace_lines, :joined_bracket_linebreaks).any?(&:positive?)
    [changed ? "prepared_safe" : "ready_as_is", []]
  end

  def summary_text(summary)
    counts = summary.fetch("status_counts")
    <<~TEXT
      Dictionary source preparation complete
      ======================================
      Documents:                 #{summary['documents']}
      Ready as-is:               #{counts['ready_as_is'].to_i}
      Safely prepared:           #{counts['prepared_safe'].to_i}
      Needs structure review:    #{counts['needs_structure_review'].to_i}
      Requires source recovery:  #{counts['requires_source_recovery'].to_i}
      Quarantined:               #{counts['quarantined'].to_i}
      Repair actions:            #{summary['repair_action_count']}
      Review rows:               #{summary['review_rows']}
      Elapsed seconds:           #{summary['elapsed_seconds']}
    TEXT
  end

  def parse_options(argv)
    options = Options.new
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby script/prepare_dictionary_sources.rb --snapshot PATH [--output PATH]"
      opts.on("--snapshot PATH", "Source snapshot directory") { |value| options.snapshot = value }
      opts.on("--output PATH", "Dry-run output directory") { |value| options.output = value }
      opts.on("-h", "--help", "Show help") { puts opts; exit 0 }
    end
    parser.parse!(argv)
    abort parser.to_s unless options.snapshot
    abort "Unexpected arguments: #{argv.join(' ')}" unless argv.empty?
    options
  end
end

exit PrepareDictionarySources.run(ARGV)
