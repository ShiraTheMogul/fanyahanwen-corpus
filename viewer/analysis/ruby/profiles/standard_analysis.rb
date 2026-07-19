#!/usr/bin/env ruby
# frozen_string_literal: true

# Fanya Hanwen Corpus: standard corpus-search analysis profile
#
# Inputs:
#   1. document_counts.csv — one body-only row per document in scope
#   2. analysis_occurrences.csv — one compact row per matched occurrence
#   3. output directory
#   4. optional comparison.csv with one dimension/left_group/right_group row
#
# This profile uses only Ruby's standard library. It deliberately runs as a
# separate process so a large analysis cannot exhaust or terminate Rails.

require "csv"
require "digest"
require "fileutils"
require "json"
require "pathname"
require "set"
require "time"
require "zlib"

class StandardAnalysis
  PROFILE = "standard_analysis"
  VERSION = 7
  SAMPLING_SEED = 202_609
  UNKNOWN = "(Unknown / unclassified)"
  DOCUMENT_HEADERS = %w[
    doc_id document_id work_id body_fingerprint duplicate_group_size representative_document_id duplicate_members_json
    path folder_path document_role title work author year_start year_end nation corpus_root macro_region polity period region
    searchable_characters occurrences matching_document
  ].freeze
  OCCURRENCE_HEADERS = %w[
    occurrence_id mode path doc_id search_start_offset search_end_offset
    matched_forms left_neighbours right_neighbours
  ].freeze
  DIMENSIONS = {
    "period" => { source: "period", label: "Period", limit: 40, chronological: true },
    "corpus_root" => { source: "corpus_root", label: "Corpus root", limit: 20, chronological: false },
    "macro_region" => { source: "macro_region", label: "Macro region", limit: 20, chronological: false },
    "polity" => { source: "polity", label: "Polity", limit: 40, chronological: false },
    "region" => { source: "region", label: "Region", limit: 30, chronological: false },
    "author" => { source: "author", label: "Author", limit: 30, chronological: false },
    "folder" => { source: "folder", label: "Folder branch", limit: 40, chronological: false },
    "document_role" => { source: "document_role_group", label: "Text or corpus layer", limit: 20, chronological: false }
  }.freeze
  EXPECTED_MACRO_REGIONS = {
    "中國漢文" => "中國",
    "日本漢文" => "日本",
    "朝鮮漢文" => "朝鮮",
    "越南漢文" => "越南",
    "琉球漢文" => "琉球",
    "西域漢文" => "西域",
    "新加坡漢文" => "新加坡",
    "馬來西亞漢文" => "馬來西亞"
  }.freeze
  METADATA_COVERAGE_FIELDS = %w[
    document_id work_id corpus_root macro_region period polity region author year_range
  ].freeze
  METRICS = {
    "occurrences" => { label: "Occurrences", column: "occurrences", multiplier: 1.0 },
    "matching_documents" => { label: "Matching documents", column: "matching_documents", multiplier: 1.0 },
    "document_prevalence" => { label: "Documents containing the query (%)", column: "document_prevalence", multiplier: 100.0 },
    "occurrences_per_million" => { label: "Occurrences per million searchable characters", column: "occurrences_per_million", multiplier: 1.0 }
  }.freeze
  ROLE_LABELS = {
    "canonical" => "Received text",
    "textual_variant" => "Variants",
    "raw" => "Raw scrapes",
    "derived_reading" => "Kanbun / Hanmun / Hanvan",
    "translation" => "Translation",
    "annotation" => "Annotation"
  }.freeze
  DIMENSION_HEADERS = %w[
    dimension group documents matching_documents occurrences searchable_characters
    document_prevalence occurrences_per_million
    mean_occurrences_per_matching_document median_occurrences_per_matching_document
    occurrence_share sort_year
  ].freeze
  CHART_HEADERS = %w[key kind dimension metric title svg png table shown_groups omitted_groups].freeze

  class DeterministicSample
    def initialize(limit:, seed:, key:)
      @limit = limit
      @seed = seed
      @key = key
      @rows = []
    end

    def add(row)
      identity = row.fetch(@key, "").to_s
      priority = Digest::SHA256.hexdigest("#{@seed}:#{identity}")
      entry = [priority, row.dup]
      if @rows.length < @limit
        @rows << entry
      else
        worst_index = @rows.each_index.max_by { |index| @rows[index][0] }
        @rows[worst_index] = entry if priority < @rows[worst_index][0]
      end
    end

    def rows
      @rows.sort_by(&:first).map(&:last)
    end
  end

  class ChartWriter
    def initialize(root)
      @root = Pathname(root)
      FileUtils.mkdir_p(@root)
    end

    def bar(key:, title:, rows:, label_key:, value_key:, x_label: nil, limit: nil)
      selected = limit ? rows.first(limit) : rows
      labels = selected.map { |row| truncate(row[label_key].to_s, 48) }
      values = selected.map { |row| numeric(row[value_key]) }
      svg_path = @root.join("#{key}.svg")
      png_path = @root.join("#{key}.png")
      write_svg_bar(svg_path, title, labels, values, x_label)
      write_png_bar(png_path, values)
      ["figures/#{key}.svg", "figures/#{key}.png"]
    end

    def line(key:, title:, rows:, label_key:, value_key:, low_key: nil, high_key: nil, y_label: nil)
      labels = rows.map { |row| truncate(row[label_key].to_s, 28) }
      values = rows.map { |row| numeric(row[value_key]) }
      lows = low_key ? rows.map { |row| numeric(row[low_key]) } : nil
      highs = high_key ? rows.map { |row| numeric(row[high_key]) } : nil
      svg_path = @root.join("#{key}.svg")
      png_path = @root.join("#{key}.png")
      write_svg_line(svg_path, title, labels, values, lows, highs, y_label)
      write_png_line(png_path, values)
      ["figures/#{key}.svg", "figures/#{key}.png"]
    end

    def comparison(key:, title:, left_label:, right_label:, left_rate:, right_rate:, left_prevalence:, right_prevalence:)
      rows = [
        { "label" => "#{left_label}: rate", "value" => left_rate },
        { "label" => "#{right_label}: rate", "value" => right_rate },
        { "label" => "#{left_label}: prevalence %", "value" => left_prevalence * 100 },
        { "label" => "#{right_label}: prevalence %", "value" => right_prevalence * 100 }
      ]
      bar(key: key, title: title, rows: rows, label_key: "label", value_key: "value")
    end

    private

    def numeric(value)
      Float(value || 0)
    rescue ArgumentError, TypeError
      0.0
    end

    def truncate(value, maximum)
      value.length > maximum ? "#{value[0, maximum - 1]}…" : value
    end

    def escape(value)
      value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
    end

    def write_svg_bar(path, title, labels, values, x_label)
      width = 1_280
      row_height = 28
      height = [[220 + labels.length * row_height, 520].max, 1_900].min
      label_width = 390
      plot_width = width - label_width - 90
      maximum = values.max.to_f
      maximum = 1.0 unless maximum.positive?
      shown = labels.each_index.to_a.first(((height - 180) / row_height).floor)
      body = shown.map.with_index do |source_index, display_index|
        y = 90 + display_index * row_height
        value = values[source_index]
        bar_width = (plot_width * value / maximum).round(2)
        <<~SVG
          <text x="#{label_width - 12}" y="#{y + 17}" text-anchor="end" font-size="14">#{escape(labels[source_index])}</text>
          <rect x="#{label_width}" y="#{y}" width="#{bar_width}" height="19" rx="2" fill="#555"/>
          <text x="#{label_width + bar_width + 7}" y="#{y + 16}" font-size="12">#{escape(format_number(value))}</text>
        SVG
      end.join
      path.write(<<~SVG, encoding: "UTF-8")
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{height}" viewBox="0 0 #{width} #{height}">
          <rect width="100%" height="100%" fill="white"/>
          <text x="40" y="42" font-family="sans-serif" font-size="24" font-weight="600">#{escape(title)}</text>
          <g font-family="sans-serif" fill="#222">#{body}</g>
          <text x="#{label_width}" y="#{height - 28}" font-family="sans-serif" font-size="14">#{escape(x_label.to_s)}</text>
        </svg>
      SVG
    end

    def write_svg_line(path, title, labels, values, lows, highs, y_label)
      width = [1_200, 120 + labels.length * 68].max
      width = [width, 2_600].min
      height = 720
      left = 90
      top = 90
      right = 45
      bottom = 180
      plot_width = width - left - right
      plot_height = height - top - bottom
      maximum = [values.max, highs&.max].compact.max.to_f
      maximum = 1.0 unless maximum.positive?
      count = [values.length, 1].max
      points = values.each_index.map do |index|
        x = count == 1 ? left + plot_width / 2.0 : left + plot_width * index / (count - 1).to_f
        y = top + plot_height * (1.0 - values[index] / maximum)
        [x, y]
      end
      polyline = points.map { |x, y| "#{x.round(2)},#{y.round(2)}" }.join(" ")
      error_bars = if lows && highs
        points.each_index.map do |index|
          x = points[index][0]
          low_y = top + plot_height * (1.0 - [lows[index], 0].max / maximum)
          high_y = top + plot_height * (1.0 - [highs[index], 0].max / maximum)
          %(<line x1="#{x}" y1="#{low_y}" x2="#{x}" y2="#{high_y}" stroke="#777"/> )
        end.join
      else
        ""
      end
      label_nodes = labels.each_index.map do |index|
        x = points[index][0]
        %(<text x="#{x}" y="#{height - bottom + 30}" transform="rotate(55 #{x} #{height - bottom + 30})" font-size="12">#{escape(labels[index])}</text>)
      end.join
      point_nodes = points.map { |x, y| %(<circle cx="#{x}" cy="#{y}" r="4" fill="#333"/>) }.join
      path.write(<<~SVG, encoding: "UTF-8")
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{height}" viewBox="0 0 #{width} #{height}">
          <rect width="100%" height="100%" fill="white"/>
          <text x="40" y="42" font-family="sans-serif" font-size="24" font-weight="600">#{escape(title)}</text>
          <line x1="#{left}" y1="#{top + plot_height}" x2="#{width - right}" y2="#{top + plot_height}" stroke="#444"/>
          <line x1="#{left}" y1="#{top}" x2="#{left}" y2="#{top + plot_height}" stroke="#444"/>
          <text x="18" y="#{top + plot_height / 2}" transform="rotate(-90 18 #{top + plot_height / 2})" font-family="sans-serif" font-size="14">#{escape(y_label.to_s)}</text>
          <g font-family="sans-serif" fill="#222">#{error_bars}<polyline points="#{polyline}" fill="none" stroke="#333" stroke-width="3"/>#{point_nodes}#{label_nodes}</g>
        </svg>
      SVG
    end

    def write_png_bar(path, values)
      width = 960
      height = 600
      pixels = blank_pixels(width, height)
      maximum = values.max.to_f
      maximum = 1.0 unless maximum.positive?
      shown = values.first(30)
      row_height = [14, (height - 80) / [shown.length, 1].max].max
      shown.each_with_index do |value, index|
        y = 35 + index * row_height
        bar_width = ((width - 150) * value.to_f / maximum).round
        fill_rect(pixels, width, height, 90, y, bar_width, [row_height - 4, 8].max, [80, 80, 80])
      end
      write_png(path, width, height, pixels)
    end

    def write_png_line(path, values)
      width = 960
      height = 600
      pixels = blank_pixels(width, height)
      maximum = values.max.to_f
      maximum = 1.0 unless maximum.positive?
      left = 70
      top = 40
      plot_width = width - 120
      plot_height = height - 110
      points = values.each_index.map do |index|
        x = values.length <= 1 ? left + plot_width / 2 : left + plot_width * index / (values.length - 1)
        y = top + (plot_height * (1.0 - values[index].to_f / maximum)).round
        [x, y]
      end
      points.each_cons(2) { |a, b| draw_line(pixels, width, height, a[0], a[1], b[0], b[1], [70, 70, 70]) }
      points.each { |x, y| fill_rect(pixels, width, height, x - 3, y - 3, 7, 7, [40, 40, 40]) }
      write_png(path, width, height, pixels)
    end

    def blank_pixels(width, height)
      Array.new(width * height * 3, 255)
    end

    def fill_rect(pixels, width, height, x, y, rect_width, rect_height, rgb)
      x0 = [[x, 0].max, width].min
      y0 = [[y, 0].max, height].min
      x1 = [[x + rect_width, 0].max, width].min
      y1 = [[y + rect_height, 0].max, height].min
      (y0...y1).each do |row|
        (x0...x1).each do |column|
          offset = (row * width + column) * 3
          pixels[offset, 3] = rgb
        end
      end
    end

    def draw_line(pixels, width, height, x0, y0, x1, y1, rgb)
      dx = (x1 - x0).abs
      sx = x0 < x1 ? 1 : -1
      dy = -(y1 - y0).abs
      sy = y0 < y1 ? 1 : -1
      error = dx + dy
      loop do
        fill_rect(pixels, width, height, x0, y0, 2, 2, rgb)
        break if x0 == x1 && y0 == y1

        twice = 2 * error
        if twice >= dy
          error += dy
          x0 += sx
        end
        if twice <= dx
          error += dx
          y0 += sy
        end
      end
    end

    def write_png(path, width, height, pixels)
      raw = String.new(capacity: height * (width * 3 + 1), encoding: Encoding::BINARY)
      height.times do |row|
        raw << "\x00".b
        start = row * width * 3
        raw << pixels[start, width * 3].pack("C*")
      end
      signature = "\x89PNG\r\n\x1A\n".b
      ihdr = [width, height, 8, 2, 0, 0, 0].pack("NNCCCCC")
      path.binwrite(signature + png_chunk("IHDR", ihdr) + png_chunk("IDAT", Zlib::Deflate.deflate(raw, Zlib::BEST_SPEED)) + png_chunk("IEND", "".b))
    end

    def png_chunk(type, data)
      payload = type.b + data
      [data.bytesize].pack("N") + payload + [Zlib.crc32(payload)].pack("N")
    end

    def format_number(value)
      return value.to_i.to_s if value.to_f == value.to_i
      format("%.4g", value)
    end
  end

  def initialize(document_path:, occurrence_path:, output_dir:, comparison_path: nil)
    @document_path = Pathname(document_path).expand_path
    @occurrence_path = Pathname(occurrence_path).expand_path
    @output_dir = Pathname(output_dir).expand_path
    @comparison_path = comparison_path && Pathname(comparison_path).expand_path
    @figure_dir = @output_dir.join("figures")
    @warnings = []
    @charts = []
    @tables = {}
  end

  def run
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    validate_inputs!
    FileUtils.mkdir_p(@figure_dir)
    remove_deprecated_outputs
    @chart_writer = ChartWriter.new(@figure_dir)

    document_state = scan_documents
    dimension_tables = build_dimension_tables(document_state)
    write_overall(document_state)
    write_dimensions(dimension_tables)
    write_metadata_quality_outputs(document_state)
    comparison = build_comparison(dimension_tables)
    render_dimension_charts(dimension_tables)
    write_document_distribution(document_state)
    write_top_documents(document_state)
    write_document_sample(document_state)

    occurrence_state = scan_occurrences(document_state, comparison)
    write_occurrence_outputs(occurrence_state, comparison)
    write_dispersion_and_duplicates(document_state, dimension_tables)
    write_time_outputs(document_state)
    write_chart_manifest
    write_report(document_state, comparison)
    write_runtime_info
    write_warnings(document_state, comparison)
    write_csv(@output_dir.join("timing.csv"), ["elapsed_seconds"], [{ "elapsed_seconds" => elapsed(started) }])
    true
  end

  private

  def remove_deprecated_outputs
    FileUtils.rm_f(@output_dir.join("nation_summary.csv"))
    Dir.glob(@figure_dir.join("nation_*.{svg,png}").to_s).each { |path| FileUtils.rm_f(path) }
  end

  def validate_inputs!
    [@document_path, @occurrence_path, @comparison_path].compact.each do |path|
      raise Errno::ENOENT, path.to_s unless path.file?
    end
    raise Errno::ENOENT, @output_dir.to_s unless @output_dir.directory?
    validate_headers(@document_path, DOCUMENT_HEADERS, "document")
    validate_headers(@occurrence_path, OCCURRENCE_HEADERS, "occurrence")
  end

  def validate_headers(path, required, label)
    headers = CSV.open(path, "rb:bom|utf-8", headers: true, invalid: :replace, undef: :replace, replace: "", &:readline).headers
    missing = required - headers
    raise ArgumentError, "Missing #{label} columns: #{missing.join(', ')}" if missing.any?
  end

  def scan_documents
    dimensions = DIMENSIONS.keys.to_h { |name| [name, Hash.new { |hash, key| hash[key] = dimension_bucket }] }
    overall = { documents: 0, matching_documents: 0, occurrences: 0, searchable_characters: 0, zero_length_documents: 0 }
    matching_frequencies = Hash.new(0)
    distribution = Hash.new(0)
    top_documents = []
    sample = DeterministicSample.new(limit: 100, seed: SAMPLING_SEED, key: "doc_id")
    fingerprint_counts = Hash.new(0)
    time_bins = Hash.new { |hash, key| hash[key] = time_bucket }
    year_groups = Hash.new { |hash, key| hash[key] = { documents: 0, occurrences: 0, searchable_characters: 0 } }
    dated_midpoint_frequencies = Hash.new(0)
    comparison_config = read_comparison_config
    comparison_docs = {}
    scope_conflicts = []
    scope_conflict_count = 0
    macro_region_conflicts = []
    macro_region_conflict_count = 0
    identifier_quality = {
      "documents" => 0,
      "numeric_document_ids" => 0,
      "fallback_document_ids" => 0,
      "numeric_work_ids" => 0,
      "missing_work_ids" => 0,
      "fully_stable_documents" => 0
    }
    identifier_fallback_documents = []
    identifier_work_groups = Hash.new do |hash, key|
      hash[key] = {
        "work_id" => key[0],
        "work" => key[1],
        "title" => key[2],
        "folder_path" => key[3],
        "documents" => 0,
        "fallback_document_ids" => 0,
        "missing_work_ids" => 0,
        "sample_path" => nil
      }
    end
    metadata_coverage = METADATA_COVERAGE_FIELDS.to_h do |field|
      [field, { "field" => field, "present" => 0, "missing" => 0 }]
    end

    each_csv(@document_path) do |row|
      normalize_document_row!(row)
      occurrences = row["occurrences"]
      exposure = row["searchable_characters"]
      matching = row["matching_document"].positive?
      overall[:documents] += 1
      overall[:matching_documents] += 1 if matching
      overall[:occurrences] += occurrences
      overall[:searchable_characters] += exposure
      overall[:zero_length_documents] += 1 unless exposure.positive?
      matching_frequencies[occurrences] += 1 if occurrences.positive?
      distribution[occurrence_bucket(occurrences)] += 1 if occurrences.positive?
      fingerprint = row["body_fingerprint"].to_s.strip
      group_size = [row["duplicate_group_size"].to_i, 1].max
      fingerprint_counts[fingerprint] += group_size unless fingerprint.empty?
      physical_root = row["path"].to_s.split("/").first.to_s
      declared_root = row["corpus_root"].to_s.strip
      if !declared_root.empty? && !physical_root.empty? && declared_root != physical_root
        scope_conflict_count += 1
        if scope_conflicts.length < 1_000
          scope_conflicts << { "document_id" => row["doc_id"], "path" => row["path"], "physical_root" => physical_root, "metadata_corpus_root" => declared_root }
        end
      end

      expected_macro_region = EXPECTED_MACRO_REGIONS[physical_root]
      declared_macro_region = row["macro_region"].to_s.strip
      if expected_macro_region && !declared_macro_region.empty? && declared_macro_region != expected_macro_region
        macro_region_conflict_count += 1
        if macro_region_conflicts.length < 10_000
          macro_region_conflicts << {
            "document_id" => row["doc_id"],
            "work_id" => row["work_id"],
            "title" => row["title"],
            "path" => row["path"],
            "physical_root" => physical_root,
            "expected_macro_region" => expected_macro_region,
            "metadata_macro_region" => declared_macro_region
          }
        end
      end

      record_identifier_quality!(identifier_quality, identifier_fallback_documents, identifier_work_groups, row)
      record_metadata_coverage!(metadata_coverage, row)

      DIMENSIONS.each_key do |dimension|
        group = dimension_value(row, dimension)
        update_dimension_bucket(dimensions[dimension][group], row)
      end

      if matching
        add_top_document(top_documents, row, 100)
        sample.add(sample_document_row(row))
        if comparison_config && keyness_dimension?(comparison_config["dimension"])
          comparison_docs[row["doc_id"].to_s] = dimension_value(row, comparison_config["dimension"])
        end
      end

      midpoint = year_midpoint(row)
      if exposure.positive? && midpoint
        century = historical_century_start(midpoint)
        update_time_bucket(time_bins[century], row)
        year_groups[midpoint][:documents] += 1
        year_groups[midpoint][:occurrences] += occurrences
        year_groups[midpoint][:searchable_characters] += exposure
        dated_midpoint_frequencies[midpoint] += 1
      end
    end

    @overall_matching_documents = overall[:matching_documents]
    @sample_document_count = sample.rows.length

    {
      dimensions: dimensions,
      overall: overall,
      matching_frequencies: matching_frequencies,
      distribution: distribution,
      top_documents: top_documents.sort_by { |row| [-row["occurrences"], row["path"].to_s] },
      sample_documents: sample.rows,
      fingerprint_counts: fingerprint_counts,
      time_bins: time_bins,
      year_groups: year_groups,
      dated_midpoint_frequencies: dated_midpoint_frequencies,
      comparison_config: comparison_config,
      comparison_docs: comparison_docs,
      scope_conflicts: scope_conflicts,
      scope_conflict_count: scope_conflict_count,
      macro_region_conflicts: macro_region_conflicts,
      macro_region_conflict_count: macro_region_conflict_count,
      identifier_quality: identifier_quality,
      identifier_fallback_documents: identifier_fallback_documents,
      identifier_work_groups: identifier_work_groups,
      metadata_coverage: metadata_coverage
    }
  end

  def record_identifier_quality!(quality, fallback_documents, work_groups, row)
    document_id = row["document_id"].to_s.strip
    work_id = row["work_id"].to_s.strip
    numeric_document_id = numeric_identifier?(document_id)
    numeric_work_id = numeric_identifier?(work_id)

    quality["documents"] += 1
    quality[numeric_document_id ? "numeric_document_ids" : "fallback_document_ids"] += 1
    quality[numeric_work_id ? "numeric_work_ids" : "missing_work_ids"] += 1
    quality["fully_stable_documents"] += 1 if numeric_document_id && numeric_work_id
    return if numeric_document_id && numeric_work_id

    reasons = []
    reasons << (document_id.match?(/\A[0-9a-f]{24}\z/i) ? "path_hash_document_id" : "non_numeric_document_id") unless numeric_document_id
    reasons << "missing_work_id" unless numeric_work_id
    record = {
      "doc_id" => row["doc_id"],
      "document_id" => document_id,
      "work_id" => work_id,
      "work" => row["work"],
      "title" => row["title"],
      "folder_path" => row["folder_path"],
      "path" => row["path"],
      "reason" => reasons.join(";")
    }
    fallback_documents << record

    group_key = [work_id.empty? ? "(missing)" : work_id, row["work"].to_s, row["title"].to_s, row["folder_path"].to_s]
    group = work_groups[group_key]
    group["documents"] += 1
    group["fallback_document_ids"] += 1 unless numeric_document_id
    group["missing_work_ids"] += 1 unless numeric_work_id
    group["sample_path"] ||= row["path"]
  end

  def record_metadata_coverage!(coverage, row)
    METADATA_COVERAGE_FIELDS.each do |field|
      present = case field
      when "document_id"
        numeric_identifier?(row["document_id"])
      when "work_id"
        numeric_identifier?(row["work_id"])
      when "year_range"
        !row["year_start"].nil? || !row["year_end"].nil?
      else
        !row[field].to_s.strip.empty?
      end
      coverage.fetch(field)[present ? "present" : "missing"] += 1
    end
  end

  def numeric_identifier?(value)
    value.to_s.strip.match?(/\A[1-9]\d*\z/)
  end

  def normalize_document_row!(row)
    %w[searchable_characters occurrences matching_document duplicate_group_size].each { |column| row[column] = integer(row[column]) }
    %w[year_start year_end].each { |column| row[column] = optional_number(row[column]) }
    row["folder"] = folder_group(row["folder_path"])
    role = clean_group(row["document_role"])
    row["document_role"] = role
    row["document_role_group"] = ROLE_LABELS.fetch(role, role)
    row
  end

  def dimension_bucket
    {
      documents: 0,
      matching_documents: 0,
      occurrences: 0,
      searchable_characters: 0,
      matching_frequency: Hash.new(0),
      year_frequency: Hash.new(0)
    }
  end

  def update_dimension_bucket(bucket, row)
    bucket[:documents] += 1
    bucket[:matching_documents] += 1 if row["matching_document"].positive?
    bucket[:occurrences] += row["occurrences"]
    bucket[:searchable_characters] += row["searchable_characters"]
    bucket[:matching_frequency][row["occurrences"]] += 1 if row["occurrences"].positive?
    year = row["year_start"]
    bucket[:year_frequency][year] += 1 if year && !year.zero?
  end

  def build_dimension_tables(state)
    total_occurrences = state[:overall][:occurrences]
    state[:dimensions].to_h do |dimension, groups|
      rows = groups.map do |group, bucket|
        {
          "dimension" => dimension,
          "group" => group,
          "documents" => bucket[:documents],
          "matching_documents" => bucket[:matching_documents],
          "occurrences" => bucket[:occurrences],
          "searchable_characters" => bucket[:searchable_characters],
          "document_prevalence" => safe_rate(bucket[:matching_documents], bucket[:documents]),
          "occurrences_per_million" => safe_rate(bucket[:occurrences], bucket[:searchable_characters], 1_000_000),
          "mean_occurrences_per_matching_document" => frequency_mean(bucket[:matching_frequency]),
          "median_occurrences_per_matching_document" => frequency_quantile(bucket[:matching_frequency], 0.5),
          "occurrence_share" => safe_rate(bucket[:occurrences], total_occurrences),
          "sort_year" => frequency_quantile(bucket[:year_frequency], 0.5, empty: nil)
        }
      end
      definition = DIMENSIONS.fetch(dimension)
      rows.sort_by! do |row|
        if definition[:chronological]
          [row["sort_year"].nil? ? 1 : 0, row["sort_year"] || 0, row["group"]]
        else
          [-row["occurrences"], -row["searchable_characters"], row["group"]]
        end
      end
      if invalid_dimension_reason(dimension, rows, state[:overall][:documents])
        @invalid_dimensions ||= {}
        @invalid_dimensions[dimension] = invalid_dimension_reason(dimension, rows, state[:overall][:documents])
        [dimension, []]
      else
        [dimension, rows]
      end
    end.reject { |_dimension, rows| rows.empty? }.to_h
  end

  def invalid_dimension_reason(dimension, rows, document_count)
    return nil unless %w[region polity period].include?(dimension)
    group_count = rows.length
    singleton_count = rows.count { |row| row["documents"].to_i == 1 }
    singleton_share = group_count.zero? ? 0.0 : singleton_count.fdiv(group_count)
    return "#{group_count} groups for #{document_count} documents" if group_count > [1_000, (document_count * 0.10).to_i].max
    return "#{(singleton_share * 100).round(1)}% of groups contain one document" if group_count > 500 && singleton_share > 0.80
    nil
  end

  def write_overall(state)
    overall = state[:overall]
    values = {
      "documents" => overall[:documents],
      "matching_documents" => overall[:matching_documents],
      "occurrences" => overall[:occurrences],
      "searchable_characters" => overall[:searchable_characters],
      "document_prevalence" => safe_rate(overall[:matching_documents], overall[:documents]),
      "occurrences_per_million" => safe_rate(overall[:occurrences], overall[:searchable_characters], 1_000_000),
      "mean_occurrences_per_matching_document" => frequency_mean(state[:matching_frequencies]),
      "median_occurrences_per_matching_document" => frequency_quantile(state[:matching_frequencies], 0.5),
      "zero_length_documents" => overall[:zero_length_documents]
    }
    state[:overall_values] = values
    write_csv(@output_dir.join("summary.csv"), %w[metric value], values.map { |metric, value| { "metric" => metric, "value" => value } })
    @tables["summary"] = "summary.csv"
  end

  def write_dimensions(tables)
    tables.each do |dimension, rows|
      filename = "#{dimension}_summary.csv"
      write_csv(@output_dir.join(filename), DIMENSION_HEADERS, rows)
      @tables[dimension] = filename
    end
  end


  def write_metadata_quality_outputs(state)
    conflicts = Array(state[:scope_conflicts])
    unless conflicts.empty?
      write_csv(@output_dir.join("scope_metadata_conflicts.csv"),
                %w[document_id path physical_root metadata_corpus_root], conflicts)
      @tables["scope_metadata_conflicts"] = "scope_metadata_conflicts.csv"
    end

    macro_conflicts = Array(state[:macro_region_conflicts])
    unless macro_conflicts.empty?
      write_csv(@output_dir.join("macro_region_scope_conflicts.csv"),
                %w[document_id work_id title path physical_root expected_macro_region metadata_macro_region], macro_conflicts)
      @tables["macro_region_scope_conflicts"] = "macro_region_scope_conflicts.csv"
    end

    quality_rows = state.fetch(:identifier_quality).map { |metric, value| { "metric" => metric, "value" => value }
    }
    write_csv(@output_dir.join("identifier_quality_summary.csv"), %w[metric value], quality_rows)
    @tables["identifier_quality_summary"] = "identifier_quality_summary.csv"

    fallback_documents = Array(state[:identifier_fallback_documents])
    unless fallback_documents.empty?
      write_csv(@output_dir.join("identifier_fallback_documents.csv"),
                %w[doc_id document_id work_id work title folder_path path reason], fallback_documents)
      @tables["identifier_fallback_documents"] = "identifier_fallback_documents.csv"
    end

    fallback_works = state.fetch(:identifier_work_groups).values.sort_by do |row|
      [-row["fallback_document_ids"].to_i, -row["missing_work_ids"].to_i, row["work_id"].to_s, row["folder_path"].to_s]
    end
    unless fallback_works.empty?
      write_csv(@output_dir.join("identifier_fallback_works.csv"),
                %w[work_id work title folder_path documents fallback_document_ids missing_work_ids sample_path], fallback_works)
      @tables["identifier_fallback_works"] = "identifier_fallback_works.csv"
    end

    total_documents = state.dig(:identifier_quality, "documents").to_i
    coverage_rows = state.fetch(:metadata_coverage).values.map do |row|
      present = row["present"].to_i
      row.merge(
        "documents" => total_documents,
        "coverage" => safe_rate(present, total_documents)
      )
    end
    write_csv(@output_dir.join("metadata_field_coverage.csv"),
              %w[field documents present missing coverage], coverage_rows)
    @tables["metadata_field_coverage"] = "metadata_field_coverage.csv"

    invalid = (@invalid_dimensions || {}).map do |dimension, reason|
      { "dimension" => dimension, "reason" => reason }
    end
    unless invalid.empty?
      write_csv(@output_dir.join("invalid_dimensions.csv"), %w[dimension reason], invalid)
      @tables["invalid_dimensions"] = "invalid_dimensions.csv"
    end
  end

  def build_comparison(dimension_tables)
    config = read_comparison_config
    return nil unless config

    dimension = config.fetch("dimension")
    raise ArgumentError, "Unsupported comparison dimension: #{dimension}" unless dimension_tables.key?(dimension)
    left = dimension_tables[dimension].find { |row| row["group"] == config["left_group"] }
    right = dimension_tables[dimension].find { |row| row["group"] == config["right_group"] }
    raise ArgumentError, "One or both selected comparison groups are absent from the analysis dataset" unless left && right

    summary = [left.merge("scope" => "left", "scope_label" => config["left_group"]), right.merge("scope" => "right", "scope_label" => config["right_group"])]
    headers = %w[
      scope scope_label dimension group documents matching_documents occurrences searchable_characters
      document_prevalence occurrences_per_million mean_occurrences_per_matching_document
      median_occurrences_per_matching_document occurrence_share sort_year
    ]
    effects = comparison_effects(summary)
    write_csv(@output_dir.join("comparison_summary.csv"), headers, summary)
    write_csv(@output_dir.join("comparison_effects.csv"), %w[measure value], effects)
    @tables["comparison_summary"] = "comparison_summary.csv"
    @tables["comparison_effects"] = "comparison_effects.csv"
    svg, png = @chart_writer.comparison(
      key: "scope_comparison",
      title: "#{config['left_group']} compared with #{config['right_group']}",
      left_label: config["left_group"],
      right_label: config["right_group"],
      left_rate: left["occurrences_per_million"],
      right_rate: right["occurrences_per_million"],
      left_prevalence: left["document_prevalence"],
      right_prevalence: right["document_prevalence"]
    )
    add_chart(key: "scope_comparison", kind: "comparison", dimension: dimension, metric: "scope_comparison",
              title: "#{config['left_group']} compared with #{config['right_group']}", svg: svg, png: png,
              table: "comparison_summary.csv", shown: 2, omitted: 0)
    config.merge("summary" => summary, "effects" => effects)
  end

  def comparison_effects(summary)
    left, right = summary
    left_count = left["occurrences"].to_f
    right_count = right["occurrences"].to_f
    left_exposure = left["searchable_characters"].to_f
    right_exposure = right["searchable_characters"].to_f
    if left_exposure.positive? && right_exposure.positive?
      corrected_left = left_count.positive? ? left_count : 0.5
      corrected_right = right_count.positive? ? right_count : 0.5
      ratio = (corrected_left / left_exposure) / (corrected_right / right_exposure)
      standard_error = Math.sqrt(1.0 / corrected_left + 1.0 / corrected_right)
      low = Math.exp(Math.log(ratio) - 1.96 * standard_error)
      high = Math.exp(Math.log(ratio) + 1.96 * standard_error)
      g2, p_value = poisson_log_likelihood(left_count, left_exposure, right_count, right_exposure)
      rate_difference = left["occurrences_per_million"].to_f - right["occurrences_per_million"].to_f
    else
      ratio = low = high = g2 = p_value = rate_difference = nil
    end
    prevalence_ratio = right["document_prevalence"].to_f.positive? ? left["document_prevalence"].to_f / right["document_prevalence"].to_f : nil
    values = {
      "rate_ratio_left_over_right" => ratio,
      "rate_ratio_ci_low_95" => low,
      "rate_ratio_ci_high_95" => high,
      "log2_rate_ratio" => ratio&.positive? ? Math.log2(ratio) : nil,
      "rate_difference_per_million" => rate_difference,
      "document_prevalence_difference_percentage_points" => (left["document_prevalence"].to_f - right["document_prevalence"].to_f) * 100,
      "document_prevalence_ratio" => prevalence_ratio,
      "poisson_log_likelihood_g2" => g2,
      "poisson_log_likelihood_p_value" => p_value
    }
    values.map { |measure, value| { "measure" => measure, "value" => value } }
  end

  def render_dimension_charts(tables)
    tables.each do |dimension, rows|
      definition = DIMENSIONS.fetch(dimension)
      next if rows.empty?

      METRICS.each do |metric, metric_definition|
        selected = select_chart_rows(rows, metric_definition[:column], definition[:limit], definition[:chronological])
        chart_rows = selected.map do |row|
          row.merge("chart_value" => row[metric_definition[:column]].to_f * metric_definition[:multiplier])
        end
        key = "#{dimension}_#{metric}"
        svg, png = @chart_writer.bar(
          key: key,
          title: "#{metric_definition[:label]} by #{definition[:label]}",
          rows: chart_rows,
          label_key: "group",
          value_key: "chart_value",
          x_label: metric_definition[:label]
        )
        add_chart(key: key, kind: "group_bar", dimension: dimension, metric: metric,
                  title: "#{metric_definition[:label]} by #{definition[:label]}", svg: svg, png: png,
                  table: "#{dimension}_summary.csv", shown: selected.length, omitted: rows.length - selected.length)
      end
    end
  end

  def write_document_distribution(state)
    labels = ["1", "2", "3–5", "6–10", "11–20", "21–50", "51–100", "101+"]
    total = state[:distribution].values.sum
    rows = labels.map do |label|
      count = state[:distribution][label]
      { "occurrences_per_document" => label, "documents" => count, "share_of_matching_documents" => safe_rate(count, total) }
    end
    write_csv(@output_dir.join("matches_per_document.csv"), %w[occurrences_per_document documents share_of_matching_documents], rows)
    @tables["matches_per_document"] = "matches_per_document.csv"
    svg, png = @chart_writer.bar(key: "matches_per_document", title: "Distribution of matches across documents", rows: rows,
                                 label_key: "occurrences_per_document", value_key: "documents", x_label: "Documents")
    add_chart(key: "matches_per_document", kind: "distribution", dimension: "document", metric: "matches_per_document",
              title: "Distribution of matches across documents", svg: svg, png: png, table: "matches_per_document.csv",
              shown: rows.length, omitted: 0)
  end

  def write_top_documents(state)
    total = state[:overall][:occurrences]
    rows = state[:top_documents].map do |row|
      row.merge(
        "occurrences_per_million" => safe_rate(row["occurrences"], row["searchable_characters"], 1_000_000),
        "occurrence_share" => safe_rate(row["occurrences"], total)
      )
    end
    headers = %w[doc_id title author period nation document_role path searchable_characters occurrences occurrences_per_million occurrence_share]
    write_csv(@output_dir.join("top_documents.csv"), headers, rows)
    @tables["top_documents"] = "top_documents.csv"
    concentration = [1, 5, 10].map do |number|
      { "measure" => "top_#{number}_share", "value" => safe_rate(rows.first(number).sum { |row| row["occurrences"] }, [total, 1].max) }
    end
    write_csv(@output_dir.join("concentration_summary.csv"), %w[measure value], concentration)
    @tables["concentration"] = "concentration_summary.csv"
  end

  def write_document_sample(state)
    headers = %w[doc_id title author period nation document_role path searchable_characters occurrences]
    write_csv(@output_dir.join("sample_documents.csv"), headers, state[:sample_documents])
    @tables["sample_documents"] = "sample_documents.csv"
  end

  def scan_occurrences(document_state, comparison)
    state = {
      count: 0,
      sample: DeterministicSample.new(limit: 100, seed: SAMPLING_SEED + 1, key: "occurrence_id"),
      headers: nil,
      neighbour_occurrences: Hash.new(0),
      neighbour_documents: Hash.new(0),
      form_occurrences: Hash.new(0),
      form_documents: Hash.new(0),
      alternative_occurrences: Hash.new(0),
      alternative_documents: Hash.new(0),
      alternative_row_count: 0,
      order_occurrences: Hash.new(0),
      order_documents: Hash.new(0),
      scope_context_counts: { "left" => Hash.new(0), "right" => Hash.new(0) },
      scope_context_totals: Hash.new(0),
      proximity_frequency: Hash.new(0),
      proximity_count: 0,
      proximity_sum: 0.0,
      proximity_writer: nil,
      saw_alternatives: false,
      saw_proximity: false
    }
    proximity_path = @output_dir.join("proximity_spans.csv")
    current_doc = nil
    per_doc_neighbours = Set.new
    per_doc_forms = Set.new
    per_doc_alternatives = Set.new
    per_doc_orders = Set.new

    flush_document = lambda do
      per_doc_neighbours.each { |key| state[:neighbour_documents][key] += 1 }
      per_doc_forms.each { |key| state[:form_documents][key] += 1 }
      per_doc_alternatives.each { |key| state[:alternative_documents][key] += 1 }
      per_doc_orders.each { |key| state[:order_documents][key] += 1 }
      per_doc_neighbours.clear
      per_doc_forms.clear
      per_doc_alternatives.clear
      per_doc_orders.clear
    end

    each_csv(@occurrence_path) do |row, headers|
      state[:headers] ||= headers
      doc_id = row["doc_id"].to_s
      if current_doc && current_doc != doc_id
        flush_document.call
      end
      current_doc = doc_id
      state[:count] += 1
      state[:sample].add(row.to_h)

      left = context_characters(row["left_neighbours"])
      right = context_characters(row["right_neighbours"])
      { "left" => left, "right" => right }.each do |side, characters|
        1.upto(5) do |distance|
          character = side == "left" ? characters[-distance] : characters[distance - 1]
          next if character.nil? || character.empty?

          key = [side, distance, character]
          state[:neighbour_occurrences][key] += 1
          per_doc_neighbours << key
        end
      end

      parse_matched_forms(row["matched_forms"]).each do |query_form, source_form|
        key = [query_form, source_form]
        state[:form_occurrences][key] += 1
        per_doc_forms << key
      end

      mode = row["mode"].to_s.strip
      if mode == "alternatives"
        state[:saw_alternatives] = true
        state[:alternative_row_count] += 1
        split_pipe(row["matched_alternatives"]).each do |alternative|
          state[:alternative_occurrences][alternative] += 1
          per_doc_alternatives << alternative
        end
      end

      if mode == "proximity"
        state[:saw_proximity] = true
        term_order = row["matched_term_order"].to_s.strip
        unless term_order.empty?
          state[:order_occurrences][term_order] += 1
          per_doc_orders << term_order
        end
        start_offset = integer(row["search_start_offset"])
        end_offset = integer(row["search_end_offset"])
        span = [end_offset - start_offset, 0].max
        unless state[:proximity_writer]
          state[:proximity_writer] = CSV.open(proximity_path, "w", encoding: "UTF-8", write_headers: true,
                                               headers: %w[occurrence_id doc_id path search_start_offset search_end_offset span])
        end
        state[:proximity_writer] << [row["occurrence_id"], doc_id, row["path"], start_offset, end_offset, span]
        state[:proximity_frequency][span] += 1
        state[:proximity_count] += 1
        state[:proximity_sum] += span
      end

      if comparison && keyness_dimension?(comparison["dimension"])
        group = document_state[:comparison_docs][doc_id]
        scope = if group == comparison["left_group"]
          "left"
        elsif group == comparison["right_group"]
          "right"
        end
        if scope
          (left + right).each do |character|
            state[:scope_context_counts][scope][character] += 1
            state[:scope_context_totals][scope] += 1
          end
        end
      end
    end
    flush_document.call if current_doc
    state[:proximity_writer]&.close
    state
  ensure
    state&.dig(:proximity_writer)&.close unless state&.dig(:proximity_writer)&.closed?
  end

  def write_occurrence_outputs(state, comparison)
    write_neighbour_tables(state)
    write_character_forms(state)
    write_occurrence_sample(state)
    write_comparison_neighbour_keyness(state, comparison)
    write_alternative_summary(state)
    write_term_order_summary(state)
    write_proximity_summary(state)
  end

  def write_neighbour_tables(state)
    totals_by_position = Hash.new(0)
    state[:neighbour_occurrences].each do |(side, distance, _character), count|
      totals_by_position[[side, distance]] += count
    end

    rows = state[:neighbour_occurrences].map do |(side, distance, character), count|
      total_at_position = totals_by_position[[side, distance]]
      {
        "side" => side,
        "distance" => distance,
        "position" => "#{side == 'left' ? 'L' : 'R'}#{distance}",
        "character" => character,
        "occurrences" => count,
        "documents" => state[:neighbour_documents][[side, distance, character]],
        "share_at_position" => safe_rate(count, total_at_position)
      }
    end
    rows.sort_by! { |row| [row["side"], row["distance"], -row["occurrences"], row["character"]] }
    headers = %w[side distance position character occurrences documents share_at_position]
    write_csv(@output_dir.join("neighbour_characters.csv"), headers, rows)
    @tables["neighbour_characters"] = "neighbour_characters.csv"

    side_totals = Hash.new { |hash, key| hash[key] = { left: 0, right: 0 } }
    rows.each { |row| side_totals[row["character"]][row["side"].to_sym] += row["occurrences"] }
    grand_total = side_totals.values.sum { |value| value[:left] + value[:right] }
    window = side_totals.map do |character, values|
      total = values[:left] + values[:right]
      {
        "character" => character,
        "left_occurrences" => values[:left],
        "right_occurrences" => values[:right],
        "total_occurrences" => total,
        "share_of_neighbour_tokens" => safe_rate(total, grand_total),
        "direction_balance" => total.positive? ? (values[:right] - values[:left]).to_f / total : 0
      }
    end.sort_by { |row| [-row["total_occurrences"], row["character"]] }
    write_csv(@output_dir.join("neighbour_window_summary.csv"),
              %w[character left_occurrences right_occurrences total_occurrences share_of_neighbour_tokens direction_balance], window)
    @tables["neighbour_window"] = "neighbour_window_summary.csv"
    return if window.empty?

    svg, png = @chart_writer.bar(key: "neighbour_characters", title: "Characters near the matched passage", rows: window.first(20),
                                 label_key: "character", value_key: "total_occurrences", x_label: "Neighbour tokens within five characters")
    add_chart(key: "neighbour_characters", kind: "neighbour", dimension: "context", metric: "neighbour_tokens",
              title: "Characters near the matched passage", svg: svg, png: png, table: "neighbour_window_summary.csv",
              shown: [20, window.length].min, omitted: [window.length - 20, 0].max)
  end

  def write_character_forms(state)
    total = state[:form_occurrences].values.sum
    rows = state[:form_occurrences].map do |(query_form, source_form), count|
      {
        "query_form" => query_form,
        "source_form" => source_form,
        "occurrences" => count,
        "documents" => state[:form_documents][[query_form, source_form]],
        "occurrence_share" => safe_rate(count, total),
        "chart_label" => query_form == source_form ? source_form : "#{query_form} → #{source_form}"
      }
    end.sort_by { |row| [-row["occurrences"], row["query_form"], row["source_form"]] }
    write_csv(@output_dir.join("character_form_summary.csv"),
              %w[query_form source_form occurrences documents occurrence_share chart_label], rows)
    @tables["character_forms"] = "character_form_summary.csv"
    return if rows.empty?

    svg, png = @chart_writer.bar(key: "character_forms", title: "Forms actually matched in the source", rows: rows.first(20),
                                 label_key: "chart_label", value_key: "occurrences", x_label: "Matched term occurrences")
    add_chart(key: "character_forms", kind: "ranked", dimension: "source_form", metric: "occurrences",
              title: "Forms actually matched in the source", svg: svg, png: png, table: "character_form_summary.csv",
              shown: [20, rows.length].min, omitted: [rows.length - 20, 0].max)
  end

  def write_occurrence_sample(state)
    headers = state[:headers] || CSV.open(@occurrence_path, "rb:bom|utf-8", headers: true, &:readline).headers
    rows = state[:sample].rows
    write_csv(@output_dir.join("sample_occurrences.csv"), headers, rows)
    @tables["sample_occurrences"] = "sample_occurrences.csv"
    manifest = [
      { "unit" => "matching_documents", "seed" => SAMPLING_SEED, "population" => nil, "sample_size" => nil },
      { "unit" => "occurrences", "seed" => SAMPLING_SEED + 1, "population" => state[:count], "sample_size" => rows.length }
    ]
    manifest[0]["sample_size"] = @sample_document_count
    manifest[0]["population"] = @overall_matching_documents
    write_csv(@output_dir.join("sampling_manifest.csv"), %w[unit seed population sample_size], manifest)
    @tables["sampling_manifest"] = "sampling_manifest.csv"
  end

  def write_comparison_neighbour_keyness(state, comparison)
    rows = []
    if comparison
      left_total = state[:scope_context_totals]["left"]
      right_total = state[:scope_context_totals]["right"]
      if left_total.positive? && right_total.positive?
        characters = (state[:scope_context_counts]["left"].keys | state[:scope_context_counts]["right"].keys).sort
        rows = characters.map do |character|
          left_count = state[:scope_context_counts]["left"][character]
          right_count = state[:scope_context_counts]["right"][character]
          g2, p_value = log_likelihood_2x2(left_count, right_count, left_total, right_total)
          corrected_left = (left_count + 0.5) / (left_total + 1.0)
          corrected_right = (right_count + 0.5) / (right_total + 1.0)
          log_ratio = Math.log2(corrected_left / corrected_right)
          favoured = log_ratio >= 0 ? comparison["left_group"] : comparison["right_group"]
          {
            "character" => character,
            "left_scope" => comparison["left_group"],
            "right_scope" => comparison["right_group"],
            "left_occurrences" => left_count,
            "right_occurrences" => right_count,
            "left_rate_per_10000" => safe_rate(left_count, left_total, 10_000),
            "right_rate_per_10000" => safe_rate(right_count, right_total, 10_000),
            "log2_rate_ratio" => log_ratio,
            "favoured_scope" => favoured,
            "log_likelihood_g2" => g2,
            "p_value" => p_value,
            "chart_label" => "#{character} (#{favoured})"
          }
        end.sort_by { |row| [-row["log_likelihood_g2"], -row["log2_rate_ratio"].abs, row["character"]] }
      end
    end
    headers = %w[character left_scope right_scope left_occurrences right_occurrences left_rate_per_10000 right_rate_per_10000 log2_rate_ratio favoured_scope log_likelihood_g2 p_value chart_label]
    write_csv(@output_dir.join("comparison_neighbour_keyness.csv"), headers, rows)
    @tables["comparison_neighbour_keyness"] = "comparison_neighbour_keyness.csv"
    return if rows.empty?

    svg, png = @chart_writer.bar(key: "comparison_neighbour_keyness", title: "Distinctive neighbouring characters in the compared scopes",
                                 rows: rows.first(20), label_key: "chart_label", value_key: "log_likelihood_g2", x_label: "Log-likelihood G²")
    add_chart(key: "comparison_neighbour_keyness", kind: "ranked", dimension: "comparison_context", metric: "log_likelihood_g2",
              title: "Distinctive neighbouring characters in the compared scopes", svg: svg, png: png,
              table: "comparison_neighbour_keyness.csv", shown: [20, rows.length].min, omitted: [rows.length - 20, 0].max)
  end

  def write_alternative_summary(state)
    return unless state[:saw_alternatives]

    rows = state[:alternative_occurrences].map do |alternative, count|
      {
        "alternative" => alternative,
        "occurrences" => count,
        "documents" => state[:alternative_documents][alternative],
        "share_of_matched_occurrences" => safe_rate(count, state[:alternative_row_count])
      }
    end.sort_by { |row| [-row["occurrences"], row["alternative"]] }
    write_csv(@output_dir.join("alternative_summary.csv"), %w[alternative occurrences documents share_of_matched_occurrences], rows)
    @tables["alternative_summary"] = "alternative_summary.csv"
    return if rows.empty?

    svg, png = @chart_writer.bar(key: "alternative_terms", title: "Matched alternatives", rows: rows.first(20),
                                 label_key: "alternative", value_key: "occurrences", x_label: "Matched occurrences")
    add_chart(key: "alternative_terms", kind: "ranked", dimension: "alternative", metric: "occurrences", title: "Matched alternatives",
              svg: svg, png: png, table: "alternative_summary.csv", shown: [20, rows.length].min, omitted: [rows.length - 20, 0].max)
  end

  def write_term_order_summary(state)
    return unless state[:saw_proximity]

    total = state[:order_occurrences].values.sum
    rows = state[:order_occurrences].map do |order, count|
      { "term_order" => order, "occurrences" => count, "documents" => state[:order_documents][order], "occurrence_share" => safe_rate(count, total) }
    end.sort_by { |row| [-row["occurrences"], row["term_order"]] }
    write_csv(@output_dir.join("term_order_summary.csv"), %w[term_order occurrences documents occurrence_share], rows)
    @tables["term_order_summary"] = "term_order_summary.csv"
    return if rows.empty?

    svg, png = @chart_writer.bar(key: "term_orders", title: "Observed term orders", rows: rows.first(20),
                                 label_key: "term_order", value_key: "occurrences", x_label: "Matched occurrences")
    add_chart(key: "term_orders", kind: "ranked", dimension: "proximity_order", metric: "occurrences", title: "Observed term orders",
              svg: svg, png: png, table: "term_order_summary.csv", shown: [20, rows.length].min, omitted: [rows.length - 20, 0].max)
  end

  def write_proximity_summary(state)
    return unless state[:saw_proximity]

    headers = %w[occurrence_id doc_id path search_start_offset search_end_offset span]
    unless @output_dir.join("proximity_spans.csv").file?
      write_csv(@output_dir.join("proximity_spans.csv"), headers, [])
    end
    count = state[:proximity_count]
    values = {
      "occurrences" => count,
      "minimum" => frequency_quantile(state[:proximity_frequency], 0.0),
      "first_quartile" => frequency_quantile(state[:proximity_frequency], 0.25),
      "median" => frequency_quantile(state[:proximity_frequency], 0.5),
      "third_quartile" => frequency_quantile(state[:proximity_frequency], 0.75),
      "maximum" => frequency_quantile(state[:proximity_frequency], 1.0),
      "mean" => count.positive? ? state[:proximity_sum] / count : 0
    }
    write_csv(@output_dir.join("proximity_summary.csv"), %w[metric value], values.map { |metric, value| { "metric" => metric, "value" => value } })
    @tables["proximity_spans"] = "proximity_spans.csv"
    @tables["proximity_summary"] = "proximity_summary.csv"
    histogram = state[:proximity_frequency].sort.map { |span, occurrences| { "span" => span, "occurrences" => occurrences } }
    svg, png = @chart_writer.bar(key: "proximity_span_histogram", title: "Proximity-match span distribution", rows: histogram.first(50),
                                 label_key: "span", value_key: "occurrences", x_label: "Occurrences")
    add_chart(key: "proximity_span_histogram", kind: "histogram", dimension: "proximity", metric: "span_distribution",
              title: "Proximity-match span distribution", svg: svg, png: png, table: "proximity_spans.csv", shown: count, omitted: 0)
  end

  def write_dispersion_and_duplicates(state, dimension_tables)
    overall = state[:overall]
    @overall_matching_documents = overall[:matching_documents]
    duplicate_fingerprints = state[:fingerprint_counts].select { |_fingerprint, count| count > 1 }.keys.to_set
    state[:fingerprint_counts] = nil
    duplicate_groups = Hash.new do |hash, fingerprint|
      hash[fingerprint] = { documents: 0, matching_documents: 0, occurrences: 0, searchable_characters: 0,
                            max_occurrences: 0, max_searchable_characters: 0, max_matching_document: 0,
                            example_title: nil, example_path: nil }
    end
    duplicate_members_path = @output_dir.join("duplicate_body_members.csv")
    duplicate_headers = %w[body_fingerprint doc_id title author period nation document_role path searchable_characters occurrences matching_document]
    unique_totals = { documents: 0, matching_documents: 0, occurrences: 0, searchable_characters: 0 }
    stored_totals = { documents: 0, matching_documents: 0, occurrences: 0, searchable_characters: 0 }
    dp_sum = 0.0
    min_expected = nil
    total_occurrences = overall[:occurrences].to_f
    total_exposure = overall[:searchable_characters].to_f

    CSV.open(duplicate_members_path, "w", encoding: "UTF-8", write_headers: true, headers: duplicate_headers) do |duplicate_csv|
      each_csv(@document_path) do |row|
        normalize_document_row!(row)
        exposure = row["searchable_characters"]
        count = row["occurrences"]
        if exposure.positive? && total_occurrences.positive? && total_exposure.positive?
          expected = exposure / total_exposure
          observed = count / total_occurrences
          dp_sum += (observed - expected).abs
          min_expected = expected if min_expected.nil? || expected < min_expected
        end

        fingerprint = row["body_fingerprint"].to_s.strip
        group_size = [row["duplicate_group_size"].to_i, 1].max
        stored_totals[:documents] += group_size
        stored_totals[:matching_documents] += group_size if row["matching_document"].positive?
        stored_totals[:occurrences] += count * group_size
        stored_totals[:searchable_characters] += exposure * group_size
        if fingerprint.empty?
          add_unique_totals(unique_totals, row)
        elsif duplicate_fingerprints.include?(fingerprint)
          members = JSON.parse(row["duplicate_members_json"].to_s) rescue []
          members = [{ "document_id" => row["doc_id"], "path" => row["path"] }] if members.empty?
          members.each do |member|
            member_row = row.to_h.merge("doc_id" => member["document_id"], "path" => member["path"])
            duplicate_csv << duplicate_headers.map { |header| member_row[header] }
          end
          group = duplicate_groups[fingerprint]
          group[:documents] += group_size
          group[:matching_documents] += group_size if row["matching_document"].positive?
          group[:occurrences] += count * group_size
          group[:searchable_characters] += exposure * group_size
          group[:max_occurrences] = [group[:max_occurrences], count].max
          group[:max_searchable_characters] = [group[:max_searchable_characters], exposure].max
          group[:max_matching_document] = [group[:max_matching_document], row["matching_document"]].max
          group[:example_title] ||= row["title"]
          group[:example_path] ||= row["path"]
        else
          add_unique_totals(unique_totals, row)
        end
      end
    end
    duplicate_groups.each_value do |group|
      unique_totals[:documents] += 1
      unique_totals[:matching_documents] += 1 if group[:max_matching_document].positive?
      unique_totals[:occurrences] += group[:max_occurrences]
      unique_totals[:searchable_characters] += group[:max_searchable_characters]
    end

    dp = total_occurrences.positive? && total_exposure.positive? ? 0.5 * dp_sum : nil
    maximum = min_expected ? 1.0 - min_expected : nil
    dp_norm = dp && maximum&.positive? ? [dp / maximum, 1.0].min : nil
    dispersion_rows = {
      "dp" => dp,
      "dp_norm" => dp_norm,
      "evenness_one_minus_dp_norm" => dp_norm ? 1.0 - dp_norm : nil,
      "document_range" => safe_rate(overall[:matching_documents], overall[:documents]),
      "matching_documents" => overall[:matching_documents],
      "documents_in_scope" => overall[:documents]
    }.map { |measure, value| { "measure" => measure, "value" => value } }
    write_csv(@output_dir.join("dispersion_summary.csv"), %w[measure value], dispersion_rows)
    @tables["dispersion"] = "dispersion_summary.csv"

    dimension_dispersion = dimension_tables.map do |dimension, rows|
      values = dispersion_values(rows.map { |row| row["occurrences"] }, rows.map { |row| row["searchable_characters"] })
      { "dimension" => dimension, "groups" => rows.length, "dp" => values[:dp], "dp_norm" => values[:dp_norm],
        "evenness_one_minus_dp_norm" => values[:evenness] }
    end
    write_csv(@output_dir.join("dimension_dispersion.csv"),
              %w[dimension groups dp dp_norm evenness_one_minus_dp_norm], dimension_dispersion)
    @tables["dimension_dispersion"] = "dimension_dispersion.csv"

    groups = duplicate_groups.map do |fingerprint, group|
      {
        "body_fingerprint" => fingerprint,
        "documents" => group[:documents],
        "matching_documents" => group[:matching_documents],
        "occurrences" => group[:occurrences],
        "searchable_characters" => group[:searchable_characters],
        "body_length" => group[:max_searchable_characters],
        "query_affecting" => group[:matching_documents].positive? || group[:occurrences].positive? ? 1 : 0,
        "example_title" => group[:example_title],
        "example_path" => group[:example_path]
      }
    end.sort_by { |row| [-row["documents"], -row["occurrences"], row["example_path"].to_s] }
    write_csv(@output_dir.join("duplicate_body_groups.csv"),
              %w[body_fingerprint documents matching_documents occurrences searchable_characters body_length query_affecting example_title example_path], groups)
    @tables["duplicate_body_groups"] = "duplicate_body_groups.csv"
    query_groups = groups.select { |row| row["query_affecting"].to_i == 1 }
    write_csv(@output_dir.join("duplicate_body_query_groups.csv"),
              %w[body_fingerprint documents matching_documents occurrences searchable_characters body_length query_affecting example_title example_path], query_groups)
    @tables["duplicate_body_query_groups"] = "duplicate_body_query_groups.csv"
    @tables["duplicate_body_members"] = "duplicate_body_members.csv"

    stored = {
      "basis" => "documents_as_stored", "documents" => stored_totals[:documents], "matching_documents" => stored_totals[:matching_documents],
      "occurrences" => stored_totals[:occurrences], "searchable_characters" => stored_totals[:searchable_characters]
    }
    unique = {
      "basis" => "unique_exact_bodies", "documents" => unique_totals[:documents], "matching_documents" => unique_totals[:matching_documents],
      "occurrences" => unique_totals[:occurrences], "searchable_characters" => unique_totals[:searchable_characters]
    }
    [stored, unique].each do |row|
      row["document_prevalence"] = safe_rate(row["matching_documents"], row["documents"])
      row["occurrences_per_million"] = safe_rate(row["occurrences"], row["searchable_characters"], 1_000_000)
    end
    write_csv(@output_dir.join("exact_body_sensitivity.csv"),
              %w[basis documents matching_documents occurrences searchable_characters document_prevalence occurrences_per_million], [stored, unique])
    @tables["exact_body_sensitivity"] = "exact_body_sensitivity.csv"

    duplicate_documents = duplicate_groups.values.sum { |group| group[:documents] }
    duplicate_occurrences = duplicate_groups.values.sum { |group| group[:occurrences] }
    duplicate_summary = {
      "duplicate_body_groups" => groups.length,
      "documents_in_duplicate_groups" => duplicate_documents,
      "occurrences_in_duplicate_groups" => duplicate_occurrences,
      "share_of_documents_in_duplicate_groups" => safe_rate(duplicate_documents, overall[:documents]),
      "share_of_occurrences_in_duplicate_groups" => safe_rate(duplicate_occurrences, overall[:occurrences]),
      "unique_exact_bodies" => unique_totals[:documents]
    }.map { |metric, value| { "metric" => metric, "value" => value } }
    write_csv(@output_dir.join("duplicate_body_summary.csv"), %w[metric value], duplicate_summary)
    @tables["duplicate_body_summary"] = "duplicate_body_summary.csv"
    state[:duplicate_group_count] = groups.length
    state[:duplicate_document_count] = duplicate_documents
    state[:document_dp_norm] = dp_norm
  end

  def write_time_outputs(state)
    rows = state[:time_bins].sort.map do |century, bucket|
      lower, upper = poisson_rate_interval(bucket[:occurrences], bucket[:searchable_characters])
      {
        "century_start" => century,
        "century_end" => century + 99,
        "century_label" => historical_century_label(century),
        "documents" => bucket[:documents],
        "matching_documents" => bucket[:matching_documents],
        "occurrences" => bucket[:occurrences],
        "searchable_characters" => bucket[:searchable_characters],
        "document_prevalence" => safe_rate(bucket[:matching_documents], bucket[:documents]),
        "occurrences_per_million" => safe_rate(bucket[:occurrences], bucket[:searchable_characters], 1_000_000),
        "rate_ci_low" => lower,
        "rate_ci_high" => upper
      }
    end
    headers = %w[century_start century_end century_label documents matching_documents occurrences searchable_characters document_prevalence occurrences_per_million rate_ci_low rate_ci_high]
    write_csv(@output_dir.join("time_bins.csv"), headers, rows)
    @tables["time_bins"] = "time_bins.csv"
    unless rows.empty?
      svg, png = @chart_writer.line(key: "time_trend", title: "Observed frequency by dated century", rows: rows,
                                    label_key: "century_label", value_key: "occurrences_per_million", low_key: "rate_ci_low", high_key: "rate_ci_high",
                                    y_label: "Occurrences per million searchable characters")
      add_chart(key: "time_trend", kind: "time", dimension: "time", metric: "occurrences_per_million",
                title: "Observed frequency by dated century", svg: svg, png: png, table: "time_bins.csv", shown: rows.length, omitted: 0)
    end

    model = fit_time_model(state)
    model_headers = %w[model_family documents distinct_year_midpoints occurrences searchable_characters median_year log_rate_change_per_century standard_error rate_ratio_per_century rate_ratio_ci_low_95 rate_ratio_ci_high_95 p_value poisson_overdispersion_ratio]
    write_csv(@output_dir.join("time_trend_model.csv"), model_headers, model ? [model] : [])
    @tables["time_trend_model"] = "time_trend_model.csv"
    state[:time_model] = model
  end

  def fit_time_model(state)
    groups = state[:year_groups]
    documents = groups.values.sum { |row| row[:documents] }
    occurrences = groups.values.sum { |row| row[:occurrences] }
    return nil unless documents >= 20 && groups.length >= 5 && occurrences >= 5

    median_year = frequency_quantile(state[:dated_midpoint_frequencies], 0.5)
    beta0 = Math.log([occurrences.to_f / groups.values.sum { |row| row[:searchable_characters] }, 1e-12].max)
    beta1 = 0.0
    40.times do
      h00 = h01 = h11 = s0 = s1 = 0.0
      groups.each do |year, row|
        x = (year - median_year) / 100.0
        exposure = row[:searchable_characters].to_f
        y = row[:occurrences].to_f
        mu = exposure * Math.exp([[beta0 + beta1 * x, 40].min, -40].max)
        residual = y - mu
        s0 += residual
        s1 += residual * x
        h00 += mu
        h01 += mu * x
        h11 += mu * x * x
      end
      determinant = h00 * h11 - h01 * h01
      return nil if determinant.abs < 1e-12

      delta0 = (h11 * s0 - h01 * s1) / determinant
      delta1 = (-h01 * s0 + h00 * s1) / determinant
      beta0 += delta0
      beta1 += delta1
      break if delta0.abs < 1e-9 && delta1.abs < 1e-9
    end
    h00 = h01 = h11 = 0.0
    groups.each do |year, row|
      x = (year - median_year) / 100.0
      mu = row[:searchable_characters].to_f * Math.exp([[beta0 + beta1 * x, 40].min, -40].max)
      h00 += mu
      h01 += mu * x
      h11 += mu * x * x
    end
    determinant = h00 * h11 - h01 * h01
    return nil if determinant.abs < 1e-12
    variance_beta1 = h00 / determinant
    standard_error = Math.sqrt([variance_beta1, 0].max)
    overdispersion = document_overdispersion(beta0, beta1, median_year, documents)
    model_family = overdispersion && overdispersion > 1.5 ? "quasipoisson" : "poisson"
    standard_error *= Math.sqrt(overdispersion) if model_family == "quasipoisson" && overdispersion.positive?
    z = standard_error.positive? ? beta1 / standard_error : 0
    p_value = Math.erfc(z.abs / Math.sqrt(2))
    {
      "model_family" => model_family,
      "documents" => documents,
      "distinct_year_midpoints" => groups.length,
      "occurrences" => occurrences,
      "searchable_characters" => groups.values.sum { |row| row[:searchable_characters] },
      "median_year" => median_year,
      "log_rate_change_per_century" => beta1,
      "standard_error" => standard_error,
      "rate_ratio_per_century" => Math.exp(beta1),
      "rate_ratio_ci_low_95" => Math.exp(beta1 - 1.96 * standard_error),
      "rate_ratio_ci_high_95" => Math.exp(beta1 + 1.96 * standard_error),
      "p_value" => p_value,
      "poisson_overdispersion_ratio" => overdispersion
    }
  end

  def document_overdispersion(beta0, beta1, median_year, document_count)
    sum = 0.0
    each_csv(@document_path) do |row|
      normalize_document_row!(row)
      midpoint = year_midpoint(row)
      exposure = row["searchable_characters"].to_f
      next unless midpoint && exposure.positive?

      x = (midpoint - median_year) / 100.0
      mu = exposure * Math.exp([[beta0 + beta1 * x, 40].min, -40].max)
      sum += (row["occurrences"].to_f - mu)**2 / mu if mu.positive?
    end
    degrees = document_count - 2
    degrees.positive? ? sum / degrees : nil
  end

  def write_chart_manifest
    write_csv(@output_dir.join("chart_manifest.csv"), CHART_HEADERS, @charts)
  end

  def write_report(state, comparison)
    report = {
      "version" => VERSION,
      "profile" => PROFILE,
      "generated_at" => Time.now.utc.iso8601,
      "overall" => state[:overall_values],
      "comparison" => comparison && {
        "dimension" => comparison["dimension"],
        "left_group" => comparison["left_group"],
        "right_group" => comparison["right_group"],
        "summary_table" => "comparison_summary.csv",
        "effects_table" => "comparison_effects.csv",
        "chart_key" => "scope_comparison"
      },
      "charts" => @charts,
      "tables" => @tables
    }
    @output_dir.join("analysis_report.json").write(JSON.pretty_generate(report), encoding: "UTF-8")
  end

  def write_runtime_info
    @output_dir.join("runtime_info.txt").write(<<~TEXT, encoding: "UTF-8")
      Ruby #{RUBY_VERSION}p#{RUBY_PATCHLEVEL} (#{RUBY_PLATFORM})
      Engine: #{defined?(RUBY_ENGINE) ? RUBY_ENGINE : "ruby"}
      Profile: #{PROFILE}
      Profile version: #{VERSION}
      Standard-library dependencies: csv, digest, fileutils, json, pathname, set, time, zlib
    TEXT
  end

  def write_warnings(state, comparison)
    if state[:overall][:zero_length_documents].positive?
      @warnings << "#{state[:overall][:zero_length_documents]} document(s) contain no searchable body characters and should have been excluded by manifest schema 7."
    end
    if state[:scope_conflict_count].to_i.positive?
      @warnings << "#{state[:scope_conflict_count]} document(s) declare a corpus_root that conflicts with their physical top-level folder; examples are listed in scope_metadata_conflicts.csv."
    end
    if state[:macro_region_conflict_count].to_i.positive?
      @warnings << "#{state[:macro_region_conflict_count]} document(s) declare a macro_region that conflicts with the physical corpus root; examples are listed in macro_region_scope_conflicts.csv."
    end
    fallback_ids = state.dig(:identifier_quality, "fallback_document_ids").to_i
    missing_work_ids = state.dig(:identifier_quality, "missing_work_ids").to_i
    if fallback_ids.positive?
      @warnings << "#{fallback_ids} document(s) still use path-hash or otherwise non-numeric document IDs; affected works are listed in identifier_fallback_works.csv."
    end
    if missing_work_ids.positive?
      @warnings << "#{missing_work_ids} document(s) have no numeric work_id; affected paths are listed in identifier_fallback_documents.csv."
    end
    (@invalid_dimensions || {}).each do |dimension, reason|
      @warnings << "#{dimension.humanize} analysis was suppressed because the field failed validation (#{reason}); repair metadata before using this dimension academically."
    end
    if comparison && comparison["summary"].any? { |row| row["occurrences"].to_i.zero? }
      @warnings << "The comparison rate-ratio confidence interval uses a 0.5 continuity correction because one selected scope has zero occurrences."
    end
    if comparison && comparison["summary"].any? { |row| row["searchable_characters"].to_i <= 0 }
      @warnings << "At least one comparison scope has no searchable body characters; exposure-based comparison statistics are unavailable."
    end
    if state[:duplicate_group_count].to_i.positive?
      @warnings << "#{state[:duplicate_group_count]} exact-body group(s) affect the stored-document sensitivity calculation; duplicate provenance is retained in duplicate_body_members.csv."
    end
    if state[:time_model] && state[:time_model]["model_family"] == "quasipoisson"
      @warnings << "The dated-document model was overdispersed, so quasi-Poisson standard errors were used."
    end
    @output_dir.join("warnings.txt").write(@warnings.uniq.join("\n") + (@warnings.empty? ? "" : "\n"), encoding: "UTF-8")
  end

  def add_chart(key:, kind:, dimension:, metric:, title:, svg:, png:, table:, shown:, omitted:)
    @charts << {
      "key" => key, "kind" => kind, "dimension" => dimension, "metric" => metric,
      "title" => title, "svg" => svg, "png" => png, "table" => table,
      "shown_groups" => shown, "omitted_groups" => [omitted, 0].max
    }
  end

  def select_chart_rows(rows, column, limit, chronological)
    return rows if rows.length <= limit

    selected = rows.sort_by { |row| [-row[column].to_f, -row["searchable_characters"].to_f, row["group"]] }.first(limit)
    if chronological
      selected.sort_by { |row| [row["sort_year"].nil? ? 1 : 0, row["sort_year"] || 0, row["group"]] }
    else
      selected.sort_by { |row| [-row[column].to_f, row["group"]] }
    end
  end

  def read_comparison_config
    return nil unless @comparison_path
    return @comparison_config if defined?(@comparison_config)

    rows = CSV.read(@comparison_path, headers: true, encoding: "bom|utf-8", invalid: :replace, undef: :replace, replace: "").map(&:to_h)
    required = %w[dimension left_group right_group]
    raise ArgumentError, "Comparison file must contain exactly one row with dimension, left_group, and right_group" unless rows.length == 1 && (required - rows.first.keys).empty?

    @comparison_config = rows.first.transform_values { |value| value.to_s.strip }
  end

  def dimension_value(row, dimension)
    case dimension
    when "period", "nation", "corpus_root", "macro_region", "polity", "region", "author"
      clean_group(row[dimension])
    when "folder"
      clean_group(row["folder"] || folder_group(row["folder_path"]))
    when "document_role"
      clean_group(row["document_role_group"] || ROLE_LABELS.fetch(clean_group(row["document_role"]), clean_group(row["document_role"])))
    else
      UNKNOWN
    end
  end

  def keyness_dimension?(dimension)
    %w[period nation region folder document_role].include?(dimension.to_s)
  end

  def each_csv(path)
    CSV.foreach(path, headers: true, encoding: "bom|utf-8", invalid: :replace, undef: :replace, replace: "") do |row|
      yield row, row.headers
    end
  end

  def write_csv(path, headers, rows)
    CSV.open(path, "w", encoding: "UTF-8", write_headers: true, headers: headers) do |csv|
      rows.each { |row| csv << headers.map { |header| csv_value(row[header]) } }
    end
  end

  def csv_value(value)
    return nil if value.nil?
    return nil if value.is_a?(Float) && !value.finite?

    value
  end

  def clean_group(value)
    result = value.to_s.strip
    result.empty? ? UNKNOWN : result
  end

  def folder_group(path)
    ignored = %w[clean raw variants variant translations translation annotations annotation kanbun hanmun hanvan]
    parts = path.to_s.split("/").reject(&:empty?).reject { |part| ignored.include?(part.downcase) }
    parts.first(3).join(" / ").then { |value| value.empty? ? UNKNOWN : value }
  end

  def occurrence_bucket(count)
    case count
    when 1 then "1"
    when 2 then "2"
    when 3..5 then "3–5"
    when 6..10 then "6–10"
    when 11..20 then "11–20"
    when 21..50 then "21–50"
    when 51..100 then "51–100"
    else "101+"
    end
  end

  def add_top_document(rows, source, limit)
    row = sample_document_row(source)
    if rows.length < limit
      rows << row
      return
    end
    worst_index = rows.each_index.min_by { |index| [rows[index]["occurrences"], -rows[index]["path"].to_s.length, rows[index]["path"].to_s] }
    worst = rows[worst_index]
    better = row["occurrences"] > worst["occurrences"] || (row["occurrences"] == worst["occurrences"] && row["path"].to_s < worst["path"].to_s)
    rows[worst_index] = row if better
  end

  def sample_document_row(row)
    %w[doc_id title author period nation document_role path searchable_characters occurrences].to_h { |key| [key, row[key]] }
  end

  def parse_matched_forms(value)
    split_pipe(value).filter_map do |entry|
      query_form, source_form = entry.split("⇒", 2).map { |piece| piece.to_s.strip }
      [query_form, source_form] unless query_form.empty? || source_form.empty?
    end.uniq
  end

  def split_pipe(value)
    value.to_s.split(" | ").map(&:strip).reject(&:empty?).uniq
  end

  def context_characters(value)
    value.to_s.scrub.each_char.reject { |character| character.match?(/[\p{P}\p{Z}\p{C}]/) }
  end

  def time_bucket
    { documents: 0, matching_documents: 0, occurrences: 0, searchable_characters: 0 }
  end

  def update_time_bucket(bucket, row)
    bucket[:documents] += 1
    bucket[:matching_documents] += 1 if row["matching_document"].positive?
    bucket[:occurrences] += row["occurrences"]
    bucket[:searchable_characters] += row["searchable_characters"]
  end

  def year_midpoint(row)
    start_year = row["year_start"]
    end_year = row["year_end"]
    start_year = nil if start_year&.zero?
    end_year = nil if end_year&.zero?
    return (start_year + end_year) / 2.0 if start_year && end_year

    start_year || end_year
  end

  def historical_century_start(year)
    year.positive? ? (((year - 1) / 100.0).floor * 100 + 1) : -(year.abs / 100.0).ceil * 100
  end

  def historical_century_label(start_year)
    end_year = start_year + 99
    start_year.positive? ? "#{start_year}–#{end_year} CE" : "#{start_year.abs}–#{end_year.abs} BCE"
  end

  def add_unique_totals(totals, row)
    totals[:documents] += 1
    totals[:matching_documents] += 1 if row["matching_document"].positive?
    totals[:occurrences] += row["occurrences"]
    totals[:searchable_characters] += row["searchable_characters"]
  end

  def dispersion_values(counts, exposures)
    pairs = counts.zip(exposures).select { |count, exposure| finite_number?(count) && finite_number?(exposure) && exposure.to_f.positive? }
    total_counts = pairs.sum { |count, _| count.to_f }
    total_exposure = pairs.sum { |_, exposure| exposure.to_f }
    return { dp: nil, dp_norm: nil, evenness: nil } if pairs.length < 2 || !total_counts.positive? || !total_exposure.positive?

    expected = pairs.map { |_, exposure| exposure.to_f / total_exposure }
    observed = pairs.map { |count, _| count.to_f / total_counts }
    dp = 0.5 * observed.zip(expected).sum { |actual, anticipated| (actual - anticipated).abs }
    maximum = 1.0 - expected.min
    dp_norm = maximum.positive? ? [dp / maximum, 1.0].min : 0
    { dp: dp, dp_norm: dp_norm, evenness: 1.0 - dp_norm }
  end

  def poisson_log_likelihood(left_count, left_exposure, right_count, right_exposure)
    total_count = left_count + right_count
    total_exposure = left_exposure + right_exposure
    return [0.0, 1.0] unless total_count.positive? && total_exposure.positive? && left_exposure.positive? && right_exposure.positive?

    expected = [total_count * left_exposure / total_exposure, total_count * right_exposure / total_exposure]
    observed = [left_count, right_count]
    statistic = 2.0 * observed.zip(expected).sum { |actual, anticipated| actual.positive? && anticipated.positive? ? actual * Math.log(actual / anticipated) : 0 }
    [statistic, Math.erfc(Math.sqrt(statistic / 2.0))]
  end

  def log_likelihood_2x2(left_count, right_count, left_total, right_total)
    observed = [[left_count.to_f, left_total - left_count.to_f], [right_count.to_f, right_total - right_count.to_f]]
    return [nil, nil] if observed.flatten.any?(&:negative?)
    grand = observed.flatten.sum
    return [nil, nil] unless grand.positive?

    row_sums = observed.map(&:sum)
    column_sums = [observed.sum { |row| row[0] }, observed.sum { |row| row[1] }]
    statistic = 0.0
    2.times do |row|
      2.times do |column|
        expected = row_sums[row] * column_sums[column] / grand
        actual = observed[row][column]
        statistic += 2.0 * actual * Math.log(actual / expected) if actual.positive? && expected.positive?
      end
    end
    [statistic, Math.erfc(Math.sqrt(statistic / 2.0))]
  end

  def poisson_rate_interval(count, exposure, multiplier = 1_000_000.0)
    return [0.0, 0.0] unless exposure.to_f.positive?
    # Garwood interval. Chi-square quantiles use a Wilson-Hilferty start refined
    # by bisection against the regularised gamma CDF.
    alpha = 0.05
    lower_count = count.to_i.positive? ? 0.5 * chi_square_quantile(alpha / 2.0, 2 * count.to_i) : 0.0
    upper_count = 0.5 * chi_square_quantile(1 - alpha / 2.0, 2 * (count.to_i + 1))
    [lower_count / exposure.to_f * multiplier, upper_count / exposure.to_f * multiplier]
  end

  def chi_square_quantile(probability, degrees)
    return 0.0 if probability <= 0
    return Float::INFINITY if probability >= 1
    low = 0.0
    high = [degrees.to_f, 1.0].max
    high *= 2 while regularized_gamma_p(degrees / 2.0, high / 2.0) < probability
    80.times do
      mid = (low + high) / 2.0
      if regularized_gamma_p(degrees / 2.0, mid / 2.0) < probability
        low = mid
      else
        high = mid
      end
    end
    (low + high) / 2.0
  end

  def regularized_gamma_p(shape, x)
    return 0.0 if x <= 0
    if x < shape + 1.0
      sum = 1.0 / shape
      term = sum
      ap = shape
      1.upto(200) do
        ap += 1
        term *= x / ap
        sum += term
        break if term.abs < sum.abs * 1e-14
      end
      sum * Math.exp(-x + shape * Math.log(x) - Math.lgamma(shape).first)
    else
      b = x + 1.0 - shape
      c = 1.0 / 1e-300
      d = 1.0 / b
      h = d
      1.upto(200) do |index|
        an = -index * (index - shape)
        b += 2.0
        d = an * d + b
        d = 1e-300 if d.abs < 1e-300
        c = b + an / c
        c = 1e-300 if c.abs < 1e-300
        d = 1.0 / d
        delta = d * c
        h *= delta
        break if (delta - 1.0).abs < 1e-14
      end
      1.0 - Math.exp(-x + shape * Math.log(x) - Math.lgamma(shape).first) * h
    end
  end

  def frequency_mean(frequency)
    count = frequency.values.sum
    return 0 if count.zero?

    frequency.sum { |value, occurrences| value.to_f * occurrences } / count.to_f
  end

  def frequency_quantile(frequency, probability, empty: 0)
    count = frequency.values.sum
    return empty if count.zero?
    sorted = frequency.sort
    position = (count - 1) * probability
    lower_index = position.floor
    upper_index = position.ceil
    lower = frequency_value_at(sorted, lower_index)
    upper = frequency_value_at(sorted, upper_index)
    lower + (upper - lower) * (position - lower_index)
  end

  def frequency_value_at(sorted_frequency, index)
    cumulative = 0
    sorted_frequency.each do |value, count|
      cumulative += count
      return value.to_f if index < cumulative
    end
    sorted_frequency.last.first.to_f
  end

  def safe_rate(numerator, denominator, multiplier = 1.0)
    denominator.to_f.positive? ? numerator.to_f / denominator.to_f * multiplier : 0.0
  end

  def integer(value)
    Integer(value.to_s, exception: false) || value.to_f.to_i
  end

  def optional_number(value)
    stripped = value.to_s.strip
    return nil if stripped.empty?

    Float(stripped, exception: false)
  end

  def finite_number?(value)
    Float(value).finite?
  rescue ArgumentError, TypeError
    false
  end

  def elapsed(start)
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start).round(6)
  end
end

if $PROGRAM_NAME == __FILE__
  unless [3, 4].include?(ARGV.length)
    warn "Usage: ruby analysis.rb document_counts.csv analysis_occurrences.csv output_directory [comparison.csv]"
    exit 64
  end

  begin
    StandardAnalysis.new(
      document_path: ARGV[0],
      occurrence_path: ARGV[1],
      output_dir: ARGV[2],
      comparison_path: ARGV[3]
    ).run
  rescue StandardError => error
    warn "#{error.class}: #{error.message}"
    warn error.backtrace.first(20).join("\n")
    exit 1
  end
end
