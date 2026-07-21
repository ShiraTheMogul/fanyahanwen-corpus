#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "dictionary_import_support"

module PlanDictionaryImports
  module_function

  Options = Struct.new(:snapshot, :output, :config, :prepared, keyword_init: true)
  TONE_RE = /\A(?:上平聲|下平聲|平聲|上聲|去聲|入聲)\z/
  RHYME_RE = /\A([〇零一二三四五六七八九十百0-9]+)\s*([^\s〈〉○]{1,8})\z/
  HEADER_NOISE_RE = /\A(?:欽定四庫全書|原本廣韻卷[一二三四五六七八九十0-9]+|.+卷[一二三四五六七八九十百0-9]+|[唐宋元明清梁漢晉]\s+.+撰)\z/
  HEAD_PUNCTUATION = /[\s\u3000《》〈〉\(\)\[\]\{\}，,。．\.、:：;；"“”'’<>]/

  def run(argv)
    options = parse_options(argv)
    snapshot = Pathname(options.snapshot).expand_path
    output = Pathname(options.output || snapshot.join("dry_runs", "import_plan")).expand_path
    config_path = Pathname(options.config || DictionaryImportSupport::DEFAULT_CONFIG).expand_path
    works_csv = snapshot.join("works.csv")
    docs_csv = snapshot.join("documents.csv")
    abort "Snapshot works.csv not found: #{works_csv}" unless works_csv.file?
    abort "Snapshot documents.csv not found: #{docs_csv}" unless docs_csv.file?

    config = DictionaryImportSupport.load_config(config_path)
    works = CSV.read(works_csv, headers: true).map(&:to_h)
    documents = CSV.read(docs_csv, headers: true).map(&:to_h)
    prepared_dir = options.prepared ? Pathname(options.prepared).expand_path : nil
    apply_prepared_paths!(documents, prepared_dir) if prepared_dir
    docs_by_title = documents.group_by { |row| row.fetch("canonical_title") }
    FileUtils.mkdir_p(output.join("samples"))

    started = Time.now
    accepted_entries = []
    quarantined_entries = []
    work_rows = []
    warning_rows = []

    puts "=" * 76
    puts "DICTIONARY IMPORT PLAN — DRY RUN"
    puts "=" * 76
    puts "Snapshot: #{snapshot}"
    puts "Works:    #{works.length}"
    puts "Output:   #{output}"
    puts

    works.each_with_index do |work, index|
      title = work.fetch("canonical_title")
      settings = DictionaryImportSupport.work_settings(config, title)
      parser = settings.fetch("parser", work["parser"] || "probe_only")
      rows = Array(docs_by_title[title]).sort_by { |row| row["document_sequence"].to_i }
      print format("[%3d/%3d] %-24s parser=%-27s ", index + 1, works.length, title, parser)

      if parser == "probe_only"
        probe = probe_work(snapshot, rows)
        status = probe_status(settings, probe)
        work_rows << base_work_row(work, parser, settings, probe).merge(
          "status" => status,
          "accepted_entries" => 0,
          "quarantined_entries" => 0,
          "matched_payload_ratio" => nil,
          "validation_failures" => status == "probe_only" ? nil : status
        )
        puts status
        next
      end

      parse_result = parse_rime_work(snapshot, work, rows, parser)
      validation_failures = validate_rime_work(parse_result)
      accepted = validation_failures.empty?
      status = accepted ? "accepted_dry_run" : "needs_parser_review"

      if accepted
        accepted_entries.concat(parse_result.fetch(:entries))
      else
        parse_result.fetch(:entries).each do |entry|
          quarantined_entries << entry.merge("quarantine_reason" => validation_failures.join(";"))
        end
      end
      parse_result.fetch(:warnings).each do |warning|
        warning_rows << warning.merge("canonical_title" => title)
      end

      sample_name = windows_safe(title) + ".json"
      DictionaryImportSupport.write_json(
        output.join("samples", sample_name),
        {
          "canonical_title" => title,
          "parser" => parser,
          "status" => status,
          "validation_failures" => validation_failures,
          "metrics" => parse_result.fetch(:metrics),
          "entries" => parse_result.fetch(:entries).first(50)
        }
      )

      metrics = parse_result.fetch(:metrics)
      work_rows << base_work_row(work, parser, settings, metrics).merge(
        "status" => status,
        "accepted_entries" => accepted ? parse_result.fetch(:entries).length : 0,
        "quarantined_entries" => accepted ? 0 : parse_result.fetch(:entries).length,
        "matched_payload_ratio" => format("%.5f", metrics.fetch(:matched_payload_ratio)),
        "validation_failures" => validation_failures.join(";")
      )
      puts "#{status} entries=#{parse_result.fetch(:entries).length} match=#{format('%.1f%%', metrics.fetch(:matched_payload_ratio) * 100)}"
    rescue StandardError => error
      warning_rows << {
        "canonical_title" => title,
        "document_id" => nil,
        "file" => nil,
        "line" => nil,
        "kind" => "work_error",
        "detail" => "#{error.class}: #{error.message}"
      }
      work_rows << base_work_row(work, parser, settings, {}).merge(
        "status" => "work_error",
        "accepted_entries" => 0,
        "quarantined_entries" => 0,
        "matched_payload_ratio" => nil,
        "validation_failures" => "#{error.class}: #{error.message}"
      )
      puts "ERROR #{error.class}"
    end

    DictionaryImportSupport.write_jsonl(output.join("entries.accepted.jsonl"), accepted_entries)
    DictionaryImportSupport.write_jsonl(output.join("entries.quarantined.jsonl"), quarantined_entries)
    work_headers = %w[canonical_title category work_id parser configured_status status documents tone_headers rhyme_headers payloads matched_payloads unmatched_payloads unmatched_heads entries accepted_entries quarantined_entries matched_payload_ratio angle_balance placeholder_count replacement_character_count max_line_length validation_failures]
    DictionaryImportSupport.write_csv(output.join("work_summary.csv"), work_headers, work_rows)
    DictionaryImportSupport.write_csv(output.join("warnings.csv"), %w[canonical_title document_id file line kind detail], warning_rows)
    DictionaryImportSupport.atomic_write(output.join("IMPORT_CONTRACT.md"), import_contract)

    status_counts = work_rows.each_with_object(Hash.new(0)) { |row, counts| counts[row["status"]] += 1 }
    summary = {
      "version" => 1,
      "mode" => "dry_run",
      "created_at" => Time.now.utc.iso8601,
      "elapsed_seconds" => (Time.now - started).round(3),
      "snapshot" => snapshot.to_s,
      "works" => works.length,
      "status_counts" => status_counts,
      "accepted_entries" => accepted_entries.length,
      "quarantined_entries" => quarantined_entries.length,
      "warnings" => warning_rows.length,
      "database_writes" => 0
    }
    DictionaryImportSupport.write_json(output.join("summary.json"), summary)
    DictionaryImportSupport.atomic_write(output.join("summary.txt"), summary_text(summary))

    puts
    puts summary_text(summary)
    puts "Reports: #{output}"
    0
  end


  def apply_prepared_paths!(documents, prepared_dir)
    report = prepared_dir.join("prepared_documents.csv")
    raise "Prepared report not found: #{report}" unless report.file?

    rows = CSV.read(report, headers: true).map(&:to_h)
    by_id = rows.to_h { |row| [row["document_id"].to_s, row] }
    documents.each do |document|
      prepared = by_id[document["document_id"].to_s]
      next unless prepared
      next unless %w[ready_as_is prepared_safe].include?(prepared["status"])
      next if prepared["prepared_relative_path"].to_s.empty?

      candidate = prepared_dir.join(prepared["prepared_relative_path"])
      document["_input_path"] = candidate.to_s if candidate.file?
      document["_input_status"] = prepared["status"]
    end
  end

  def input_path(snapshot, row)
    explicit = row["_input_path"].to_s
    return Pathname(explicit) unless explicit.empty?

    snapshot.join(row.fetch("snapshot_relative_path"))
  end

  def probe_work(snapshot, rows)
    metrics = base_metrics
    rows.each do |row|
      text = DictionaryImportSupport.safe_read_text(input_path(snapshot, row))
      metrics[:documents] += 1
      metrics[:angle_open_count] += text.count("〈")
      metrics[:angle_close_count] += text.count("〉")
      metrics[:placeholder_count] += text.lines.count { |line| line.strip.match?(/\A<經部,[^>]+>\z/) }
      metrics[:replacement_character_count] += text.count("\uFFFD")
      metrics[:max_line_length] = [metrics[:max_line_length], text.lines.map { |line| line.chomp.length }.max.to_i].max
      text.each_line do |line|
        stripped = line.delete("\uFEFF").strip
        metrics[:tone_headers] += 1 if stripped.match?(TONE_RE)
        metrics[:rhyme_headers] += 1 if stripped.match?(RHYME_RE)
      end
    end
    metrics[:angle_balance] = metrics[:angle_open_count] - metrics[:angle_close_count]
    metrics
  end

  def probe_status(settings, probe)
    configured = settings.fetch("status", "catalogued")
    return "incomplete_source" if probe[:placeholder_count] >= 3
    return "invalid_text" if probe[:replacement_character_count].positive? || !probe[:angle_balance].zero?
    return configured if configured != "catalogued"

    "probe_only"
  end

  def parse_rime_work(snapshot, work, rows, parser)
    state = {
      tone: nil,
      rhyme_label: nil,
      rhyme_number: nil,
      rhyme_sequence: 0,
      group_sequence: 0,
      entry_sequence: 0,
      pending_head: nil,
      pending_group_start: false,
      group_has_entry: false
    }
    entries = []
    warnings = []
    metrics = base_metrics

    rows.each do |row|
      path = input_path(snapshot, row)
      text = DictionaryImportSupport.safe_read_text(path).delete("\uFEFF")
      metrics[:documents] += 1
      metrics[:replacement_character_count] += text.count("\uFFFD")
      metrics[:placeholder_count] += text.lines.count { |line| line.strip.match?(/\A<經部,[^>]+>\z/) }
      metrics[:max_line_length] = [metrics[:max_line_length], text.lines.map { |line| line.chomp.length }.max.to_i].max

      logical_lines, angle_metrics = logical_lines_with_payloads(text)
      metrics[:angle_open_count] += angle_metrics.fetch(:opens)
      metrics[:angle_close_count] += angle_metrics.fetch(:closes)
      metrics[:negative_angle_depth] ||= angle_metrics.fetch(:negative)

      logical_lines.each do |logical|
        raw = logical.fetch(:text)
        stripped = raw.strip
        next if stripped.empty?

        if stripped.match?(TONE_RE)
          state[:tone] = stripped
          state[:rhyme_label] = nil
          state[:rhyme_number] = nil
          state[:pending_head] = nil
          metrics[:tone_headers] += 1
          next
        end

        if (match = stripped.match(RHYME_RE)) && !stripped.match?(HEADER_NOISE_RE)
          number = DictionaryImportSupport.parse_chinese_number(match[1])
          if number
            state[:rhyme_sequence] += 1
            state[:rhyme_number] = number
            state[:rhyme_label] = match[2]
            state[:group_sequence] = 0
            state[:group_has_entry] = false
            state[:pending_head] = nil
            metrics[:rhyme_headers] += 1
            next
          end
        end

        tokens = tokenize_line(raw, state)
        tokens.each do |token|
          case token.fetch(:type)
          when :head
            if state[:pending_head]
              metrics[:unmatched_heads] += 1
              warnings << warning(row, logical[:line_start], "head_replaced_before_payload", state[:pending_head])
            end
            state[:pending_head] = token.fetch(:value)
            state[:pending_group_start] = token.fetch(:group_start)
          when :payload
            metrics[:payloads] += 1
            head = state[:pending_head]
            unless head
              metrics[:unmatched_payloads] += 1
              warnings << warning(row, logical[:line_start], "payload_without_head", token.fetch(:value)[0, 100])
              next
            end

            if state[:group_sequence].zero? || state[:pending_group_start]
              state[:group_sequence] += 1
              state[:group_has_entry] = false
            end
            state[:entry_sequence] += 1
            is_group_head = !state[:group_has_entry]
            fanqie, definition = split_fanqie(token.fetch(:value))
            entries << {
              "schema_version" => 1,
              "parser" => parser,
              "parser_version" => "dictionary-discovery-v1",
              "dictionary_title" => work.fetch("canonical_title"),
              "dictionary_work_id" => integer_or_string(work["work_id"]),
              "category" => work["category"],
              "document_id" => integer_or_string(row["document_id"]),
              "source_file" => row["file"],
              "source_path" => row["source_relative_path"],
              "source_line_start" => logical[:line_start],
              "source_line_end" => logical[:line_end],
              "sequence_number" => state[:entry_sequence],
              "tone" => state[:tone],
              "rhyme_number" => state[:rhyme_number],
              "rhyme_label" => state[:rhyme_label],
              "rhyme_sequence" => state[:rhyme_sequence],
              "group_sequence" => state[:group_sequence],
              "is_group_head" => is_group_head,
              "headword" => head,
              "fanqie" => fanqie,
              "definition" => definition,
              "payload_raw" => token.fetch(:value),
              "contains_unresolved_glyph" => head == "□" || token.fetch(:value).include?("□")
            }
            metrics[:matched_payloads] += 1
            state[:group_has_entry] = true
            state[:pending_head] = nil
            state[:pending_group_start] = false
          end
        end
      end
    end

    if state[:pending_head]
      metrics[:unmatched_heads] += 1
      warnings << {
        "document_id" => nil,
        "file" => nil,
        "line" => nil,
        "kind" => "final_unmatched_head",
        "detail" => state[:pending_head]
      }
    end

    metrics[:entries] = entries.length
    metrics[:angle_balance] = metrics[:angle_open_count] - metrics[:angle_close_count]
    metrics[:matched_payload_ratio] = metrics[:payloads].zero? ? 0.0 : metrics[:matched_payloads].to_f / metrics[:payloads]
    { entries: entries, warnings: warnings, metrics: metrics }
  end

  def logical_lines_with_payloads(text)
    rows = []
    buffer = +""
    depth = 0
    start_line = 1
    opens = 0
    closes = 0
    negative = false

    text.each_line.with_index(1) do |line, line_no|
      start_line = line_no if buffer.empty?
      line.chomp.each_char do |char|
        opens += 1 if char == "〈"
        closes += 1 if char == "〉"
        depth += 1 if char == "〈"
        depth -= 1 if char == "〉"
        negative = true if depth.negative?
        buffer << char
      end

      if depth.positive?
        next
      end

      rows << { text: buffer, line_start: start_line, line_end: line_no }
      buffer = +""
    end
    rows << { text: buffer, line_start: start_line, line_end: text.lines.length } unless buffer.empty?
    [rows, { opens: opens, closes: closes, negative: negative }]
  end

  def tokenize_line(raw, state)
    tokens = []
    cursor = 0
    while (open_index = raw.index("〈", cursor))
      outside = raw[cursor...open_index]
      head = extract_head(outside)
      tokens << { type: :head, value: head.fetch(:head), group_start: head.fetch(:group_start) } if head
      close_index = raw.index("〉", open_index + 1)
      break unless close_index

      tokens << { type: :payload, value: raw[(open_index + 1)...close_index].to_s.strip }
      cursor = close_index + 1
    end

    tail = raw[cursor..].to_s
    head = extract_head(tail)
    tokens << { type: :head, value: head.fetch(:head), group_start: head.fetch(:group_start) } if head

    # A standalone line with exactly one head must carry into the next line.
    if tokens.empty?
      head = extract_head(raw)
      tokens << { type: :head, value: head.fetch(:head), group_start: head.fetch(:group_start) } if head
    end
    tokens
  end

  def extract_head(segment)
    raw = segment.to_s
    return nil if raw.strip.empty?
    return nil if raw.strip.match?(TONE_RE) || raw.strip.match?(RHYME_RE) || raw.strip.match?(HEADER_NOISE_RE)

    group_start = raw.include?("○")
    cleaned = raw.gsub(HEAD_PUNCTUATION, "").delete("○")
    chars = cleaned.each_char.to_a
    return nil unless chars.length == 1

    char = chars.first
    { head: char, group_start: group_start }
  end

  def split_fanqie(payload)
    text = payload.to_s.strip
    index = text.index("切")
    return [nil, text] unless index && index <= 8

    [text[0..index], text[(index + 1)..].to_s.strip]
  end

  def validate_rime_work(result)
    metrics = result.fetch(:metrics)
    failures = []
    failures << "fewer_than_50_entries" if metrics[:entries] < 50
    failures << "no_tone_headers" if metrics[:tone_headers].zero?
    failures << "no_rhyme_headers" if metrics[:rhyme_headers].zero?
    failures << "payload_match_below_90_percent" if metrics[:matched_payload_ratio] < 0.90
    failures << "unbalanced_angle_brackets" if metrics[:negative_angle_depth] || !metrics[:angle_balance].zero?
    failures << "replacement_characters" if metrics[:replacement_character_count].positive?
    failures << "source_template_placeholders" if metrics[:placeholder_count] >= 3
    failures
  end

  def base_metrics
    {
      documents: 0,
      tone_headers: 0,
      rhyme_headers: 0,
      payloads: 0,
      matched_payloads: 0,
      unmatched_payloads: 0,
      unmatched_heads: 0,
      entries: 0,
      angle_open_count: 0,
      angle_close_count: 0,
      angle_balance: 0,
      negative_angle_depth: false,
      placeholder_count: 0,
      replacement_character_count: 0,
      max_line_length: 0,
      matched_payload_ratio: 0.0
    }
  end

  def base_work_row(work, parser, settings, metrics)
    {
      "canonical_title" => work["canonical_title"],
      "category" => work["category"],
      "work_id" => work["work_id"],
      "parser" => parser,
      "configured_status" => settings["status"],
      "documents" => metrics[:documents].to_i,
      "tone_headers" => metrics[:tone_headers].to_i,
      "rhyme_headers" => metrics[:rhyme_headers].to_i,
      "payloads" => metrics[:payloads].to_i,
      "matched_payloads" => metrics[:matched_payloads].to_i,
      "unmatched_payloads" => metrics[:unmatched_payloads].to_i,
      "unmatched_heads" => metrics[:unmatched_heads].to_i,
      "entries" => metrics[:entries].to_i,
      "angle_balance" => metrics[:angle_balance].to_i,
      "placeholder_count" => metrics[:placeholder_count].to_i,
      "replacement_character_count" => metrics[:replacement_character_count].to_i,
      "max_line_length" => metrics[:max_line_length].to_i
    }
  end

  def warning(row, line, kind, detail)
    {
      "document_id" => row["document_id"],
      "file" => row["file"],
      "line" => line,
      "kind" => kind,
      "detail" => detail
    }
  end

  def integer_or_string(value)
    value.to_s.match?(/\A\d+\z/) ? value.to_i : value
  end

  def windows_safe(value)
    cleaned = value.to_s.gsub(/[<>:"\/\\|?*\x00-\x1F]/, "_").strip
    cleaned.empty? ? "untitled" : cleaned
  end

  def import_contract
    <<~MARKDOWN
      # Dictionary import discovery contract

      `entries.accepted.jsonl` is a dry-run intermediate format. It does not
      represent database writes and must be reviewed before a Rails importer is
      connected to it.

      Every row preserves:

      - dictionary work and document IDs;
      - source path and line range;
      - source sequence order;
      - tone, rhyme, and group context where detected;
      - headword;
      - raw payload;
      - conservatively extracted fanqie and definition;
      - unresolved-glyph status;
      - parser name and parser version.

      The intended Rails pattern is:

      source files -> source-specific parser -> normalized JSONL -> validation -> database

      The source-specific parser may improve later without changing the shared
      normalized entry contract.
    MARKDOWN
  end

  def summary_text(summary)
    counts = summary.fetch("status_counts")
    <<~TEXT
      Dictionary import dry run complete
      ==================================
      Works:                    #{summary['works']}
      Accepted works:           #{counts['accepted_dry_run'].to_i}
      Parser-review works:      #{counts['needs_parser_review'].to_i}
      Probe-only/catalogued:    #{summary['works'] - counts['accepted_dry_run'].to_i - counts['needs_parser_review'].to_i - counts['work_error'].to_i}
      Work errors:              #{counts['work_error'].to_i}
      Accepted entry rows:      #{summary['accepted_entries']}
      Quarantined entry rows:   #{summary['quarantined_entries']}
      Warnings:                 #{summary['warnings']}
      Database writes:          #{summary['database_writes']}
      Elapsed seconds:          #{summary['elapsed_seconds']}
    TEXT
  end

  def parse_options(argv)
    options = Options.new
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby script/plan_dictionary_imports.rb --snapshot PATH [options]"
      opts.on("--snapshot PATH", "Source snapshot directory") { |value| options.snapshot = value }
      opts.on("--output PATH", "Dry-run output directory") { |value| options.output = value }
      opts.on("--config PATH", "Source catalogue YAML") { |value| options.config = value }
      opts.on("--prepared PATH", "Optional source-preparation output to consume after review") { |value| options.prepared = value }
      opts.on("-h", "--help", "Show help") { puts opts; exit 0 }
    end
    parser.parse!(argv)
    abort parser.to_s unless options.snapshot
    abort "Unexpected arguments: #{argv.join(' ')}" unless argv.empty?
    options
  end
end

exit PlanDictionaryImports.run(ARGV)
