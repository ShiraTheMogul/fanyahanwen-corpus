#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "time"

# Compares the currently imported/previous 五音集韻 JSONL with parser v10.
# This is a zero-write explanation report: it shows exactly what changed rather
# than hiding a large replacement behind one new total.
module CompareWuyinJiyunImports
  module_function

  Options = Struct.new(:previous, :current, :output, keyword_init: true)

  def run(argv)
    options = parse_options(argv)
    previous_path = Pathname(options.previous).expand_path
    current_path = Pathname(options.current).expand_path
    output = Pathname(options.output).expand_path
    abort "Previous JSONL missing: #{previous_path}" unless previous_path.file?
    abort "Current JSONL missing: #{current_path}" unless current_path.file?

    previous = load_jsonl(previous_path)
    current = load_jsonl(current_path)
    FileUtils.rm_rf(output) if output.directory?
    FileUtils.mkdir_p(output)

    previous_by_key = previous.group_by { |row| lexical_key(row) }
    current_by_key = current.group_by { |row| lexical_key(row) }
    common_keys = previous_by_key.keys & current_by_key.keys

    moved = []
    common_keys.each do |key|
      old_rows = previous_by_key.fetch(key)
      new_rows = current_by_key.fetch(key)
      next unless old_rows.length == 1 && new_rows.length == 1

      old = old_rows.first
      new = new_rows.first
      old_shape = structural_shape(old)
      new_shape = structural_shape(new)
      next if old_shape == new_shape

      moved << csv_row(old, "previous").merge(
        "current_sequence_number" => new["sequence_number"],
        "current_tone" => new["tone"],
        "current_section_sequence" => new["section_sequence"],
        "current_rhyme_number" => new["rhyme_number"],
        "current_rhyme_label" => new["rhyme_label"],
        "current_initial" => new["initial"],
        "current_group_sequence" => new["group_sequence"],
        "current_group_head" => new["is_group_head"],
        "current_fanqie" => new["fanqie"]
      )
    end

    previous_only = (previous_by_key.keys - current_by_key.keys).flat_map { |key| previous_by_key.fetch(key) }
    current_only = (current_by_key.keys - previous_by_key.keys).flat_map { |key| current_by_key.fetch(key) }

    write_csv(output.join("entries_with_changed_structure.csv"), moved_headers, moved)
    write_csv(output.join("previous_only_entries.csv"), simple_headers, previous_only.map { |row| csv_row(row, "previous") })
    write_csv(output.join("current_only_entries.csv"), simple_headers, current_only.map { |row| csv_row(row, "current") })

    old_summary = summarize(previous)
    new_summary = summarize(current)
    summary = {
      "version" => 1,
      "mode" => "zero_write_comparison",
      "created_at" => Time.now.utc.iso8601,
      "previous_file" => previous_path.to_s,
      "current_file" => current_path.to_s,
      "previous_sha256" => Digest::SHA256.file(previous_path).hexdigest,
      "current_sha256" => Digest::SHA256.file(current_path).hexdigest,
      "previous" => old_summary,
      "current" => new_summary,
      "entry_delta" => new_summary["entries"] - old_summary["entries"],
      "section_delta" => new_summary["sections"] - old_summary["sections"],
      "group_delta" => new_summary["pronunciation_groups"] - old_summary["pronunciation_groups"],
      "explicit_reading_delta" => new_summary["explicit_reading_groups"] - old_summary["explicit_reading_groups"],
      "entries_with_changed_structure" => moved.length,
      "previous_only_entries" => previous_only.length,
      "current_only_entries" => current_only.length,
      "corpus_writes" => 0,
      "database_writes" => 0
    }
    output.join("summary.json").write(JSON.pretty_generate(summary) + "\n")
    output.join("summary.txt").write(summary_text(summary))
    puts summary_text(summary)
    0
  end

  def load_jsonl(path)
    File.foreach(path, encoding: "utf-8").filter_map do |line|
      stripped = line.strip
      JSON.parse(stripped) unless stripped.empty?
    end
  end

  def lexical_key(row)
    [
      row["document_id"].to_s,
      row["source_line_start"].to_i,
      row["source_line_end"].to_i,
      row["headword"].to_s,
      row["payload_raw"].to_s
    ]
  end

  def structural_shape(row)
    %w[tone section_sequence rhyme_number rhyme_label initial group_sequence is_group_head fanqie].map { |field| row[field] }
  end

  def summarize(rows)
    sections = rows.map { |row| [row["document_id"], row["section_sequence"]] }.uniq
    groups = rows.select { |row| row["group_sequence"].to_i.positive? }
      .map { |row| [row["document_id"], row["section_sequence"], row["group_sequence"]] }.uniq
    group_heads = rows.select { |row| row["is_group_head"] == true }
    {
      "entries" => rows.length,
      "sections" => sections.length,
      "sections_by_tone" => sections.to_h do |document_id, section_sequence|
        row = rows.find { |entry| entry["document_id"] == document_id && entry["section_sequence"] == section_sequence }
        [[document_id, section_sequence], row && row["tone"]]
      end.values.compact.tally,
      "pronunciation_groups" => groups.length,
      "explicit_reading_groups" => group_heads.count { |row| row["pronunciation_marker_raw"].to_s != "" },
      "entries_without_tone" => rows.count { |row| row["tone"].to_s.empty? },
      "single_numeral_headwords" => rows.count { |row| %w[一 二 三 四 五 六 七 八 九 十].include?(row["headword"]) }
    }
  end

  def csv_row(row, source)
    {
      "source" => source,
      "document_id" => row["document_id"],
      "source_file" => row["source_file"],
      "source_line_start" => row["source_line_start"],
      "source_line_end" => row["source_line_end"],
      "sequence_number" => row["sequence_number"],
      "headword" => row["headword"],
      "tone" => row["tone"],
      "section_sequence" => row["section_sequence"],
      "rhyme_number" => row["rhyme_number"],
      "rhyme_label" => row["rhyme_label"],
      "initial" => row["initial"],
      "group_sequence" => row["group_sequence"],
      "group_head" => row["is_group_head"],
      "fanqie" => row["fanqie"],
      "payload_raw" => row["payload_raw"]
    }
  end

  def simple_headers
    %w[source document_id source_file source_line_start source_line_end sequence_number headword tone section_sequence rhyme_number rhyme_label initial group_sequence group_head fanqie payload_raw]
  end

  def moved_headers
    simple_headers + %w[current_sequence_number current_tone current_section_sequence current_rhyme_number current_rhyme_label current_initial current_group_sequence current_group_head current_fanqie]
  end

  def write_csv(path, headers, rows)
    CSV.open(path, "wb:utf-8", write_headers: true, headers: headers, force_quotes: true) do |csv|
      rows.each { |row| csv << headers.map { |header| row[header] } }
    end
  end

  def summary_text(summary)
    old = summary.fetch("previous")
    current = summary.fetch("current")
    <<~TEXT
      五音集韻 import comparison
      ========================
      Mode:                              ZERO-WRITE
      Previous entries:                  #{old['entries']}
      Current entries:                   #{current['entries']} (delta #{summary['entry_delta']})
      Previous sections:                 #{old['sections']}
      Current sections:                  #{current['sections']} (delta #{summary['section_delta']})
      Previous pronunciation groups:     #{old['pronunciation_groups']}
      Current pronunciation groups:      #{current['pronunciation_groups']} (delta #{summary['group_delta']})
      Previous explicit reading groups:  #{old['explicit_reading_groups']}
      Current explicit reading groups:   #{current['explicit_reading_groups']} (delta #{summary['explicit_reading_delta']})
      Previous entries without tone:     #{old['entries_without_tone']}
      Current entries without tone:      #{current['entries_without_tone']}
      Previous single-numeral headwords:        #{old['single_numeral_headwords']}
      Current single-numeral headwords:         #{current['single_numeral_headwords']}
      Entries with changed structure:    #{summary['entries_with_changed_structure']}
      Previous-only lexical rows:        #{summary['previous_only_entries']}
      Current-only lexical rows:         #{summary['current_only_entries']}
      Corpus writes:                     0
      Database writes:                   0
    TEXT
  end

  def parse_options(argv)
    options = Options.new
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby script/compare_wuyin_jiyun_imports.rb --previous FILE --current FILE --output DIR"
      opts.on("--previous FILE", "Currently imported/previous JSONL") { |value| options.previous = value }
      opts.on("--current FILE", "Parser v10 ready JSONL") { |value| options.current = value }
      opts.on("--output DIR", "Comparison report directory") { |value| options.output = value }
    end
    parser.parse!(argv)
    abort parser.to_s unless options.previous && options.current && options.output
    options
  end
end

exit CompareWuyinJiyunImports.run(ARGV) if $PROGRAM_NAME == __FILE__
