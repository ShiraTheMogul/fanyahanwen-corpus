#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "yaml"
require "time"

# Builds a reviewable geography/period mapping report from corpus metadata audit output.
#
# This script is read-only. It reads field_values.csv from corpus_metadata_audit.rb
# and suggests how old NATION/TIMES/REGION values should map into the proposed
# JSON metadata fields:
#   corpus_root, macro_region, period, polity, region.
#
# It does not edit corpus files and it does not generate JSON sidecars.
class CorpusMetadataGeographyMapping
  DEFAULT_KEYS = %w[NATION TIMES REGION].freeze
  OUTPUT_CSV = "geography_mapping_suggestions.csv"
  UNMAPPED_CSV = "unmapped_geography_values.csv"
  SUMMARY_JSON = "geography_mapping_summary.json"
  SUMMARY_MD = "GEOGRAPHY_MAPPING_REPORT.md"

  DYNASTY_SUFFIX_PATTERN = /(?:朝|王朝)\z/
  YEARISH_PATTERN = /\A\d{3,4}年(?:\d{1,2}月(?:\d{1,2}日)?)?\z/
  RANGE_OR_TRANSITION_PATTERN = /(?:transition|待分類|近現代|近代|現代)/i

  OUTPUT_HEADERS = %i[
    raw_key value count status source corpus_root macro_region period polity region confidence notes sample_paths
  ].freeze

  def initialize(audit_output:, mapping_path:, output_root:, keys:, include_blank: false)
    @audit_output = Pathname(audit_output).expand_path
    @mapping_path = Pathname(mapping_path).expand_path
    @output_root = Pathname(output_root).expand_path
    @keys = keys
    @include_blank = include_blank
    @mapping = load_mapping
    @rows = []
    @unmapped = []
  end

  def run
    validate!
    FileUtils.mkdir_p(@output_root)
    started = Time.now.utc

    each_field_value do |row|
      next unless @keys.include?(row.fetch("raw_key"))
      next if row.fetch("value").to_s.empty? && !@include_blank

      suggestion = classify(row)
      @rows << suggestion
      @unmapped << suggestion if suggestion[:status] == "unmapped"
    end

    write_csv(@output_root.join(OUTPUT_CSV), @rows, OUTPUT_HEADERS)
    write_csv(@output_root.join(UNMAPPED_CSV), @unmapped, OUTPUT_HEADERS)
    write_summary(started: started, finished: Time.now.utc)
    warn "[metadata-map] wrote #{@rows.length} suggestions to #{@output_root}"
  end

  private

  def validate!
    raise ArgumentError, "Audit output directory does not exist: #{@audit_output}" unless @audit_output.directory?
    raise ArgumentError, "Missing field_values.csv in #{@audit_output}" unless field_values_path.file?
    raise ArgumentError, "Mapping file does not exist: #{@mapping_path}" unless @mapping_path.file?
  end

  def field_values_path
    @audit_output.join("field_values.csv")
  end

  def load_mapping
    YAML.safe_load(@mapping_path.read, permitted_classes: [Symbol], aliases: false) || {}
  rescue Psych::SyntaxError => error
    raise ArgumentError, "Bad mapping YAML #{@mapping_path}: #{error.message}"
  end

  def each_field_value
    CSV.foreach(field_values_path, headers: true, encoding: "UTF-8") do |row|
      yield row.to_h
    end
  end

  def classify(row)
    raw_key = row.fetch("raw_key")
    value = row.fetch("value").to_s.strip
    count = row.fetch("count").to_i
    sample_paths = row["sample_paths"].to_s

    base = {
      raw_key: raw_key,
      value: value,
      count: count,
      sample_paths: sample_paths
    }

    return base.merge(status: "blank", source: "blank", confidence: "high", notes: "Blank value; usually omit or null in JSON.") if value.empty?

    if (mapped = explicit_value_mapping(value))
      return base.merge(mapped).merge(status: "mapped", source: "explicit")
    end

    if (mapped = explicit_corpus_root_mapping(value))
      return base.merge(mapped).merge(status: "mapped", source: "corpus_root", confidence: mapped[:confidence] || "high")
    end

    case raw_key
    when "NATION"
      classify_old_nation(base, value)
    when "TIMES"
      classify_old_times(base, value)
    when "REGION"
      classify_old_region(base, value)
    else
      base.merge(status: "unmapped", source: "unsupported_key", confidence: "low", notes: "Key not handled by this script.")
    end
  end

  def explicit_value_mapping(value)
    values = @mapping.fetch("values", {})
    raw = values[value]
    return nil unless raw

    stringify_mapping(raw)
  end

  def explicit_corpus_root_mapping(value)
    roots = @mapping.fetch("corpus_roots", {})
    raw = roots[value]
    return nil unless raw

    stringify_mapping(raw).merge(corpus_root: value)
  end

  def stringify_mapping(raw)
    raw.each_with_object({}) do |(key, value), hash|
      next if value.nil?

      hash[key.to_s.to_sym] = value.to_s
    end
  end

  def classify_old_nation(base, value)
    if dynasty_period_value?(value)
      period = normalise_period(value)
      return base.merge(
        status: "mapped",
        source: "dynasty_period_rule",
        macro_region: infer_macro_region_for_period(period),
        period: period,
        polity: infer_polity_from_period(period),
        confidence: "medium",
        notes: "Dynasty-style value treated as period; review polity inference."
      )
    end

    base.merge(status: "unmapped", source: "old_nation_unmapped", confidence: "low", notes: "Old NATION value needs explicit review.")
  end

  def classify_old_times(base, value)
    if yearish?(value)
      return base.merge(status: "mapped", source: "times_yearish", period: value, confidence: "medium", notes: "Year-like TIMES value; preserve as date/period label pending final schema.")
    end

    if range_or_transition?(value)
      return base.merge(status: "mapped", source: "times_period_note", period: value, confidence: "medium", notes: "Modern/transition/uncertain period label; review final normalisation.")
    end

    base.merge(status: "mapped", source: "times_default_period", period: value, confidence: "medium", notes: "TIMES is treated as period by default.")
  end

  def classify_old_region(base, value)
    base.merge(status: "mapped", source: "region_default", region: value, confidence: "medium", notes: "REGION is treated as smaller region/place by default.")
  end

  def dynasty_period_value?(value)
    return false if value.start_with?("朝鮮") && value != "朝鮮王朝"

    value.match?(DYNASTY_SUFFIX_PATTERN)
  end

  def normalise_period(value)
    value.tr("淸囯戸", "清國戶")
  end

  def infer_macro_region_for_period(period)
    case period
    when /(?:朝鮮|高麗|大韓)/
      "朝鮮"
    when /(?:江戶|明治|平安|奈良|飛鳥|安土桃山|大日本)/
      "日本"
    when /(?:阮|西山|後黎|北屬)/
      "越南"
    when /(?:琉球|尚氏)/
      "琉球"
    else
      "中國"
    end
  end

  def infer_polity_from_period(period)
    return "朝鮮" if period == "朝鮮王朝"
    return "琉球國" if period.include?("尚氏")
    return "大明" if period == "明朝"
    return "大清" if period == "清朝"

    period.sub(/王朝\z/, "").sub(/朝\z/, "")
  end

  def yearish?(value)
    value.match?(YEARISH_PATTERN)
  end

  def range_or_transition?(value)
    value.match?(RANGE_OR_TRANSITION_PATTERN)
  end

  def write_csv(path, rows, headers)
    CSV.open(path, "w", write_headers: true, headers: headers, encoding: "UTF-8") do |csv|
      rows.each { |row| csv << headers.map { |header| row[header] } }
    end
  end

  def write_summary(started:, finished:)
    counts_by_status = @rows.group_by { |row| row[:status] }.transform_values(&:length)
    counts_by_key = @rows.group_by { |row| row[:raw_key] }.transform_values(&:length)
    counts_by_source = @rows.group_by { |row| row[:source] }.transform_values(&:length)
    summary = {
      version: 1,
      started_at: started.iso8601,
      finished_at: finished.iso8601,
      duration_seconds: (finished - started).round(3),
      audit_output: @audit_output.to_s,
      mapping_path: @mapping_path.to_s,
      keys: @keys,
      values_seen: @rows.length,
      unmapped_values: @unmapped.length,
      counts_by_status: counts_by_status,
      counts_by_key: counts_by_key,
      counts_by_source: counts_by_source
    }
    @output_root.join(SUMMARY_JSON).write(JSON.pretty_generate(summary))

    lines = []
    lines << "# Geography/period mapping suggestions"
    lines << ""
    lines << "- Audit output: `#{@audit_output}`"
    lines << "- Mapping seed: `#{@mapping_path}`"
    lines << "- Values processed: `#{@rows.length}`"
    lines << "- Unmapped values: `#{@unmapped.length}`"
    lines << ""
    lines << "## Counts by status"
    lines << ""
    counts_by_status.sort.each { |status, count| lines << "- `#{status}`: `#{count}`" }
    lines << ""
    lines << "## Counts by source"
    lines << ""
    counts_by_source.sort.each { |source, count| lines << "- `#{source}`: `#{count}`" }
    lines << ""
    lines << "## Output files"
    lines << ""
    lines << "- `#{OUTPUT_CSV}` — all suggestions for the requested metadata keys"
    lines << "- `#{UNMAPPED_CSV}` — values that need explicit human review/mapping"
    lines << "- `#{SUMMARY_JSON}` — machine-readable summary"
    @output_root.join(SUMMARY_MD).write(lines.join("\n") + "\n")
  end
end

options = {
  audit_output: nil,
  mapping_path: Pathname(__dir__).join("../config/corpus_metadata/geography_period_map.yml").expand_path,
  output_root: Pathname("tmp/corpus_metadata_audit/geography_mapping_#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}").expand_path,
  keys: CorpusMetadataGeographyMapping::DEFAULT_KEYS,
  include_blank: false
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby script/corpus_metadata_geography_mapping.rb --audit-output PATH [options]"
  opts.on("--audit-output PATH", "Directory containing field_values.csv from corpus_metadata_audit.rb") { |value| options[:audit_output] = Pathname(value) }
  opts.on("--mapping PATH", "Mapping seed YAML; default: config/corpus_metadata/geography_period_map.yml") { |value| options[:mapping_path] = Pathname(value) }
  opts.on("--output PATH", "Output directory") { |value| options[:output_root] = Pathname(value) }
  opts.on("--keys x,y,z", Array, "Metadata keys to inspect; default: NATION,TIMES,REGION") { |value| options[:keys] = value }
  opts.on("--include-blank", "Include blank values in the mapping report") { options[:include_blank] = true }
  opts.on("-h", "--help", "Show help") do
    puts opts
    exit 0
  end
end.parse!

unless options[:audit_output]
  warn "Missing --audit-output PATH"
  exit 1
end

CorpusMetadataGeographyMapping.new(**options).run
