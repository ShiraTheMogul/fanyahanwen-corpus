#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "dictionary_import/support"

module StageDictionarySources
  module_function

  Options = Struct.new(:bundle, :output, keyword_init: true)
  DOCUMENT_HEADERS = %w[
    configured_title metadata_title category work_id document_sequence document_id file
    source_relative_path snapshot_relative_path body_start_line
  ].freeze

  def run(argv)
    options = parse_options(argv)
    bundle = Pathname(options.bundle).expand_path
    output = Pathname(options.output || bundle.join("dry_run", "source_staging")).expand_path
    docs_path = bundle.join("documents.csv")
    abort "Bundle documents.csv not found: #{docs_path}" unless docs_path.file?

    documents = CSV.read(docs_path, headers: true).map(&:to_h)
    FileUtils.rm_rf(output) if output.directory?
    prepared_root = output.join("prepared")
    line_map_root = output.join("line_maps")
    FileUtils.mkdir_p(prepared_root)
    FileUtils.mkdir_p(line_map_root)

    document_rows = []
    action_rows = []
    recovery_rows = []
    work_stats = Hash.new { |hash, key| hash[key] = Hash.new(0) }
    started = Time.now

    puts "=" * 78
    puts "DICTIONARY SOURCE STAGING — DRY RUN"
    puts "=" * 78
    puts "Bundle:    #{bundle}"
    puts "Documents: #{documents.length}"
    puts "Output:    #{output}"
    puts

    documents.each_with_index do |row, index|
      title = row.fetch("configured_title")
      print format("[%4d/%4d] %-26s %-34s ", index + 1, documents.length, title, row["file"].to_s[0, 34])
      source_path = bundle.join(row.fetch("snapshot_relative_path"))
      unless source_path.file?
        document_rows << row.merge("status" => "missing_snapshot_file", "prepared_relative_path" => nil)
        recovery_rows << recovery(row, "missing_snapshot_file", source_path.to_s)
        work_stats[title]["missing_snapshot_file"] += 1
        puts "MISSING"
        next
      end

      text = DictionaryImport::Support.read_utf8(source_path)
      prepared, metrics, actions, line_map = stage_text(text, title: title, file: row["file"])
      status, reasons = classify(metrics)
      target = prepared_root.join(
        DictionaryImport::Support.portable_work_dir(row["work_id"], title),
        format("%04d--%s", row["document_sequence"].to_i, DictionaryImport::Support.portable_component(row["file"]))
      )
      DictionaryImport::Support.atomic_write(target, prepared)
      map_path = line_map_root.join("#{row['document_id']}.csv")
      DictionaryImport::Support.write_csv(map_path, %w[prepared_line source_line_start source_line_end action], line_map)

      actions.each do |action, count|
        next if count.to_i.zero?
        action_rows << {
          "configured_title" => title,
          "document_id" => row["document_id"],
          "file" => row["file"],
          "action" => action,
          "count" => count
        }
      end
      reasons.each { |reason| recovery_rows << recovery(row, reason, metrics.fetch(reason.to_sym, nil)) }

      document_rows << row.merge(
        "prepared_relative_path" => DictionaryImport::Support.relative(target, output),
        "line_map_relative_path" => DictionaryImport::Support.relative(map_path, output),
        "prepared_sha256" => DictionaryImport::Support.sha256(target),
        "status" => status,
        "reason_codes" => reasons.join(";"),
        "original_bytes" => source_path.size,
        "prepared_bytes" => target.size,
        "bom_removed" => metrics[:bom_removed],
        "newline_changes" => metrics[:newline_changes],
        "trailing_whitespace_lines" => metrics[:trailing_whitespace_lines],
        "joined_payload_lines" => metrics[:joined_payload_lines],
        "terminal_template_marker_removed" => metrics[:terminal_template_marker_removed],
        "embedded_template_markers" => metrics[:embedded_template_markers],
        "angle_open_count" => metrics[:angle_open_count],
        "angle_close_count" => metrics[:angle_close_count],
        "angle_balance" => metrics[:angle_balance],
        "negative_angle_depth" => metrics[:negative_angle_depth],
        "replacement_character_count" => metrics[:replacement_character_count],
        "unresolved_square_count" => metrics[:unresolved_square_count],
        "line_count" => metrics[:line_count],
        "nonblank_line_count" => metrics[:nonblank_line_count],
        "median_line_length" => metrics[:median_line_length],
        "max_line_length" => metrics[:max_line_length],
        "flattened_line_count" => metrics[:flattened_line_count],
        "payload_count" => metrics[:payload_count],
        "group_separator_count" => metrics[:group_separator_count],
        "single_han_line_count" => metrics[:single_han_line_count]
      )
      work_stats[title][status] += 1
      work_stats[title]["documents"] += 1
      work_stats[title]["payloads"] += metrics[:payload_count]
      work_stats[title]["squares"] += metrics[:unresolved_square_count]
      puts "#{status}#{reasons.empty? ? '' : " (#{reasons.join(',')})"}"
    rescue StandardError => error
      document_rows << row.merge("status" => "staging_error", "prepared_relative_path" => nil)
      recovery_rows << recovery(row, "staging_error", "#{error.class}: #{error.message}")
      work_stats[title]["staging_error"] += 1
      puts "ERROR #{error.class}"
    end

    work_rows = work_stats.keys.sort.map do |title|
      values = work_stats.fetch(title)
      {
        "configured_title" => title,
        "documents" => values["documents"],
        "ready" => values["ready"],
        "ready_with_repairs" => values["ready_with_repairs"],
        "source_recovery_required" => values["source_recovery_required"],
        "table_or_structure_review" => values["table_or_structure_review"],
        "invalid_text" => values["invalid_text"],
        "missing_snapshot_file" => values["missing_snapshot_file"],
        "staging_error" => values["staging_error"],
        "payloads" => values["payloads"],
        "unresolved_squares" => values["squares"]
      }
    end

    headers = DOCUMENT_HEADERS + %w[
      prepared_relative_path line_map_relative_path prepared_sha256 status reason_codes
      original_bytes prepared_bytes bom_removed newline_changes trailing_whitespace_lines
      joined_payload_lines terminal_template_marker_removed embedded_template_markers
      angle_open_count angle_close_count angle_balance negative_angle_depth
      replacement_character_count unresolved_square_count line_count nonblank_line_count
      median_line_length max_line_length flattened_line_count payload_count
      group_separator_count single_han_line_count
    ]
    DictionaryImport::Support.write_csv(output.join("prepared_documents.csv"), headers, document_rows)
    DictionaryImport::Support.write_csv(output.join("repair_actions.csv"), %w[configured_title document_id file action count], action_rows)
    DictionaryImport::Support.write_csv(output.join("source_recovery.csv"), %w[configured_title document_id file reason detail source_relative_path], recovery_rows)
    DictionaryImport::Support.write_csv(
      output.join("work_summary.csv"),
      %w[configured_title documents ready ready_with_repairs source_recovery_required table_or_structure_review invalid_text missing_snapshot_file staging_error payloads unresolved_squares],
      work_rows
    )

    status_counts = document_rows.each_with_object(Hash.new(0)) { |row, out| out[row["status"]] += 1 }
    summary = {
      "version" => 3,
      "mode" => "dry_run",
      "created_at" => Time.now.utc.iso8601,
      "elapsed_seconds" => (Time.now - started).round(3),
      "bundle" => bundle.to_s,
      "documents" => documents.length,
      "status_counts" => status_counts,
      "repair_action_rows" => action_rows.length,
      "repair_affected_units" => action_rows.sum { |row| row["count"].to_i },
      "source_recovery_rows" => recovery_rows.length,
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

  def stage_text(text, title:, file:)
    metrics = {
      bom_removed: 0,
      newline_changes: 0,
      trailing_whitespace_lines: 0,
      joined_payload_lines: 0,
      terminal_template_marker_removed: 0,
      embedded_template_markers: 0,
      angle_open_count: 0,
      angle_close_count: 0,
      angle_balance: 0,
      negative_angle_depth: false,
      replacement_character_count: text.count("\uFFFD"),
      unresolved_square_count: text.count("□"),
      line_count: 0,
      nonblank_line_count: 0,
      median_line_length: 0,
      max_line_length: 0,
      flattened_line_count: 0,
      payload_count: 0,
      group_separator_count: 0,
      single_han_line_count: 0
    }

    normalized = text.dup
    bom_index = normalized.index("\uFEFF")
    if bom_index && normalized[0...bom_index].match?(/\A\s*\z/)
      normalized.slice!(bom_index)
      metrics[:bom_removed] = 1
    end
    metrics[:newline_changes] = normalized.scan(/\r\n/).length + normalized.scan(/\r(?!\n)/).length
    normalized = normalized.gsub("\r\n", "\n").tr("\r", "\n")

    source_lines = normalized.split("\n", -1)
    source_lines.map! do |line|
      clean = line.rstrip
      metrics[:trailing_whitespace_lines] += 1 if clean != line
      clean
    end

    marker_re = /\A\s*<[^>]*經部[^>]*>\s*\z/
    nonblank_indexes = source_lines.each_index.select { |index| !source_lines[index].strip.empty? }
    terminal_index = nonblank_indexes.last
    if terminal_index && source_lines[terminal_index].match?(marker_re)
      source_lines.delete_at(terminal_index)
      metrics[:terminal_template_marker_removed] = 1
    end
    metrics[:embedded_template_markers] = source_lines.count { |line| line.match?(marker_re) }

    prepared_lines = []
    line_map = []
    buffer = +""
    depth = 0
    source_start = 1
    action = "unchanged"

    source_lines.each_with_index do |line, index|
      source_line = index + 1
      source_start = source_line if buffer.empty?
      line.each_char do |char|
        if char == "〈"
          metrics[:angle_open_count] += 1
          depth += 1
        elsif char == "〉"
          metrics[:angle_close_count] += 1
          depth -= 1
          metrics[:negative_angle_depth] = true if depth.negative?
        end
        buffer << char
      end

      if depth.positive?
        metrics[:joined_payload_lines] += 1
        action = "joined_inside_angle_payload"
        next
      end

      prepared_lines << buffer
      line_map << {
        "prepared_line" => prepared_lines.length,
        "source_line_start" => source_start,
        "source_line_end" => source_line,
        "action" => action
      }
      buffer = +""
      action = "unchanged"
    end
    unless buffer.empty?
      prepared_lines << buffer
      line_map << {
        "prepared_line" => prepared_lines.length,
        "source_line_start" => source_start,
        "source_line_end" => source_lines.length,
        "action" => "unterminated_angle_payload"
      }
    end

    metrics[:angle_balance] = metrics[:angle_open_count] - metrics[:angle_close_count]
    metrics[:line_count] = prepared_lines.length
    nonblank = prepared_lines.reject { |line| line.strip.empty? }
    metrics[:nonblank_line_count] = nonblank.length
    lengths = nonblank.map(&:length).sort
    metrics[:median_line_length] = lengths.empty? ? 0 : lengths[lengths.length / 2]
    metrics[:max_line_length] = lengths.max.to_i
    metrics[:flattened_line_count] = nonblank.count { |line| line.length > 800 }
    metrics[:payload_count] = prepared_lines.sum { |line| line.count("〈") }
    metrics[:group_separator_count] = prepared_lines.sum { |line| line.count("○") }
    metrics[:single_han_line_count] = nonblank.count { |line| line.strip.match?(/\A\p{Han}\z/u) }

    prepared = prepared_lines.join("\n")
    prepared << "\n" unless prepared.end_with?("\n")
    actions = {
      "remove_leading_bom" => metrics[:bom_removed],
      "normalize_newlines" => metrics[:newline_changes],
      "remove_trailing_whitespace" => metrics[:trailing_whitespace_lines],
      "join_physical_lines_inside_angle_payload" => metrics[:joined_payload_lines],
      "remove_terminal_scraper_template_marker" => metrics[:terminal_template_marker_removed],
      "ensure_final_newline" => text.end_with?("\n") ? 0 : 1
    }
    [prepared, metrics, actions, line_map]
  end

  def classify(metrics)
    reasons = []
    if metrics[:replacement_character_count].positive? || metrics[:negative_angle_depth] || !metrics[:angle_balance].zero?
      reasons << "replacement_character_count" if metrics[:replacement_character_count].positive?
      reasons << "unbalanced_angle_brackets" if metrics[:negative_angle_depth] || !metrics[:angle_balance].zero?
      return ["invalid_text", reasons]
    end
    if metrics[:embedded_template_markers].positive?
      reasons << "embedded_template_markers"
      return ["source_recovery_required", reasons]
    end
    if metrics[:flattened_line_count].positive?
      reasons << "flattened_line_count"
      return ["table_or_structure_review", reasons]
    end
    changed = metrics.values_at(:bom_removed, :newline_changes, :trailing_whitespace_lines, :joined_payload_lines, :terminal_template_marker_removed).any?(&:positive?)
    [changed ? "ready_with_repairs" : "ready", reasons]
  end

  def recovery(row, reason, detail)
    {
      "configured_title" => row["configured_title"],
      "document_id" => row["document_id"],
      "file" => row["file"],
      "reason" => reason,
      "detail" => detail,
      "source_relative_path" => row["source_relative_path"]
    }
  end

  def summary_text(summary)
    counts = summary.fetch("status_counts")
    <<~TEXT
      Dictionary source staging complete
      ==================================
      Documents:                    #{summary['documents']}
      Ready unchanged:              #{counts['ready'].to_i}
      Ready with safe repairs:      #{counts['ready_with_repairs'].to_i}
      Source recovery required:     #{counts['source_recovery_required'].to_i}
      Table/structure review:       #{counts['table_or_structure_review'].to_i}
      Invalid text:                 #{counts['invalid_text'].to_i}
      Missing snapshot file:        #{counts['missing_snapshot_file'].to_i}
      Staging errors:               #{counts['staging_error'].to_i}
      Repair action rows:           #{summary['repair_action_rows']}
      Repair affected units:        #{summary['repair_affected_units']}
      Source-recovery rows:         #{summary['source_recovery_rows']}
      Corpus writes:                0
      Database writes:              0
      Elapsed seconds:              #{summary['elapsed_seconds']}
    TEXT
  end

  def parse_options(argv)
    options = Options.new
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby script/stage_dictionary_sources.rb --bundle PATH [--output PATH]"
      opts.on("--bundle PATH", "Extracted source bundle") { |value| options.bundle = value }
      opts.on("--output PATH", "Staging output directory") { |value| options.output = value }
      opts.on("-h", "--help", "Show help") { puts opts; exit 0 }
    end
    parser.parse!(argv)
    abort parser.to_s unless options.bundle
    abort "Unexpected arguments: #{argv.join(' ')}" unless argv.empty?
    options
  end
end

exit StageDictionarySources.run(ARGV)
