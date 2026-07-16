#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "time"
require "yaml"

# Audits and, when --apply is supplied, repairs unambiguous geography fields in
# per-work metadata.json files. It never guesses a region from folder depth.
class CorpusMetadataRepairGeography
  Result = Struct.new(:path, :action, :field, :old_value, :new_value, :reason, :confidence, keyword_init: true)

  def initialize(root:, mapping:, output:, apply: false, backup: false)
    @root = Pathname(root).realpath
    @mapping_path = Pathname(mapping).expand_path
    @output = Pathname(output).expand_path
    @apply = apply
    @backup = backup
    @mapping = YAML.safe_load(@mapping_path.read, aliases: false) || {}
    @results = []
    @files_seen = 0
    @files_changed = 0
    @files_blocked = 0
  end

  def run
    FileUtils.mkdir_p(@output)
    started = Time.now.utc
    each_metadata_path do |path|
      @files_seen += 1
      repair(path)
      warn "[metadata-geography] #{@files_seen} metadata files checked" if (@files_seen % 10_000).zero?
    end
    write_reports(started)
    warn "[metadata-geography] #{@files_seen} checked; #{@files_changed} changed; #{@files_blocked} conflicts"
  end

  private

  def each_metadata_path
    stack = [@root]
    until stack.empty?
      directory = stack.pop
      begin
        children = Dir.children(directory)
      rescue Errno::ENOENT, Errno::EACCES, Errno::EIO => e
        @results << Result.new(path: relative(directory), action: "skipped", reason: "#{e.class}: #{e.message}", confidence: "none")
        next
      end

      children.each do |name|
        next if name.start_with?(".") || %w[tmp log storage vendor node_modules].include?(name)
        path = directory.join(name)
        begin
          stat = File.lstat(path)
          next if stat.symlink?
          if stat.directory?
            stack << path
          elsif name == "metadata.json"
            yield path
          end
        rescue Errno::ENOENT, Errno::EACCES, Errno::EIO => e
          @results << Result.new(path: relative(path), action: "skipped", reason: "#{e.class}: #{e.message}", confidence: "none")
        end
      end
    end
  end

  def repair(path)
    data = JSON.parse(path.read(encoding: "UTF-8"))
    original = JSON.generate(data)
    physical_root = relative(path).split("/").first.to_s

    root_mapping = @mapping.fetch("corpus_roots", {}).fetch(physical_root, {})
    expected_macro_region = root_mapping["macro_region"].to_s

    normalize_root_field(data, "corpus_root", physical_root, expected_macro_region, path)
    normalize_macro_region(data, physical_root, expected_macro_region, path)

    region = data["region"].to_s.strip
    unless region.empty?
      mapped = @mapping.fetch("values", {})[region]
      title_values = [data["title"], data["work_base_title"], data["work_title"], data["page_title"]].compact.map(&:to_s)

      if title_values.include?(region) || data["is_compilation"] == true && data["title"].to_s == region
        clear_field(data, "region", path, "work or compilation title leaked into region", "high")
      elsif region == data["period"].to_s || region == data["polity"].to_s
        clear_field(data, "region", path, "region duplicates period/polity", "high")
      elsif mapped.is_a?(Hash) && (mapped["period"].to_s != "" || mapped["polity"].to_s != "") && mapped["region"].to_s.empty?
        conflict = false
        %w[period polity macro_region].each do |field|
          value = mapped[field].to_s
          next if value.empty?
          conflict ||= !assign_if_blank(data, field, value, path, "mapped misplaced region value #{region}", mapped["confidence"] || "high")
        end
        if conflict
          @files_blocked += 1
          @results << Result.new(path: relative(path), action: "blocked", field: "region", old_value: region, reason: "mapped value conflicts with existing metadata", confidence: "low")
        else
          clear_field(data, "region", path, "moved mapped period/polity out of region", mapped["confidence"] || "high")
        end
      end
    end

    return if JSON.generate(data) == original
    @files_changed += 1
    return unless @apply

    FileUtils.cp(path, "#{path}.bak") if @backup
    temp = path.sub_ext(".json.tmp-#{Process.pid}-#{Thread.current.object_id}")
    temp.write(JSON.pretty_generate(data) + "\n", encoding: "UTF-8")
    File.rename(temp, path)
  rescue JSON::ParserError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError, SystemCallError => e
    @files_blocked += 1
    @results << Result.new(path: relative(path), action: "blocked", reason: "#{e.class}: #{e.message}", confidence: "none")
  end


  def normalize_root_field(data, field, physical_root, expected_macro_region, path)
    current = data[field].to_s.strip
    return assign_if_blank(data, field, physical_root, path, "physical top-level corpus root", "high") if current.empty?
    return true if current == physical_root

    aliases = [expected_macro_region, physical_root.sub(/漢文\z/, ""), "#{expected_macro_region}漢文"].reject(&:empty?).uniq
    if aliases.include?(current)
      replace_field(data, field, physical_root, path, "normalised legacy corpus-root alias to physical root", "high")
      true
    else
      @results << Result.new(path: relative(path), action: "conflict", field: field, old_value: current, new_value: physical_root, reason: "physical top-level corpus root", confidence: "low")
      @files_blocked += 1
      false
    end
  end

  def normalize_macro_region(data, physical_root, expected, path)
    return true if expected.empty?
    current = data["macro_region"].to_s.strip
    return assign_if_blank(data, "macro_region", expected, path, "corpus-root mapping", "high") if current.empty?
    return true if current == expected

    aliases = [physical_root, physical_root.sub(/漢文\z/, ""), "#{expected}漢文"].uniq
    if aliases.include?(current)
      replace_field(data, "macro_region", expected, path, "normalised legacy macro-region alias", "high")
      true
    else
      @results << Result.new(path: relative(path), action: "conflict", field: "macro_region", old_value: current, new_value: expected, reason: "corpus-root mapping", confidence: "low")
      @files_blocked += 1
      false
    end
  end

  def replace_field(data, field, value, path, reason, confidence)
    old = data[field]
    data[field] = value
    @results << Result.new(path: relative(path), action: @apply ? "applied" : "would_apply", field: field, old_value: old, new_value: value, reason: reason, confidence: confidence)
  end

  def assign_if_blank(data, field, value, path, reason, confidence)
    return true if value.to_s.empty?
    current = data[field].to_s.strip
    if current.empty?
      data[field] = value
      @results << Result.new(path: relative(path), action: @apply ? "applied" : "would_apply", field: field, old_value: current, new_value: value, reason: reason, confidence: confidence)
      true
    elsif current == value.to_s
      true
    else
      @results << Result.new(path: relative(path), action: "conflict", field: field, old_value: current, new_value: value, reason: reason, confidence: "low")
      false
    end
  end

  def clear_field(data, field, path, reason, confidence)
    old = data[field]
    return if old.to_s.empty?
    data.delete(field)
    @results << Result.new(path: relative(path), action: @apply ? "applied" : "would_apply", field: field, old_value: old, new_value: nil, reason: reason, confidence: confidence)
  end

  def relative(path)
    Pathname(path).relative_path_from(@root).to_s.tr("\\", "/").dup.force_encoding(Encoding::UTF_8).scrub
  rescue ArgumentError
    path.to_s
  end

  def write_reports(started)
    headers = %w[path action field old_value new_value reason confidence]
    CSV.open(@output.join("geography_repairs.csv"), "w", write_headers: true, headers: headers, encoding: "UTF-8") do |csv|
      @results.each { |r| csv << headers.map { |h| r.public_send(h) } }
    end
    summary = {
      version: 1, generated_at: Time.now.utc.iso8601, duration_seconds: (Time.now.utc - started).round(3),
      root: @root.to_s, mapping: @mapping_path.to_s, apply: @apply, backup: @backup,
      metadata_files_checked: @files_seen, metadata_files_changed: @files_changed,
      blocked_or_unreadable: @files_blocked, actions: @results.group_by(&:action).transform_values(&:length)
    }
    @output.join("geography_repairs_summary.json").write(JSON.pretty_generate(summary) + "\n")
  end
end

options = { root: ENV["CORPUS_ROOT"], mapping: File.expand_path("../config/corpus_metadata/geography_period_map.yml", __dir__), output: "tmp/corpus_metadata_geography_repair", apply: false, backup: false }
OptionParser.new do |o|
  o.on("--root PATH") { |v| options[:root] = v }
  o.on("--mapping PATH") { |v| options[:mapping] = v }
  o.on("--output PATH") { |v| options[:output] = v }
  o.on("--apply") { options[:apply] = true }
  o.on("--backup") { options[:backup] = true }
end.parse!
abort "Provide --root PATH or CORPUS_ROOT" if options[:root].to_s.empty?
CorpusMetadataRepairGeography.new(**options).run
