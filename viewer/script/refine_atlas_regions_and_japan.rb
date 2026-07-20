#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "pathname"
require "time"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

module AtlasRegionRefinement
  module_function

  EXCLUDED_ROOTS = ["他漢文"].freeze
  JAPAN_CHILD_PERIODS = [
    "奈良時代",
    "平安時代",
    "鎌倉時代",
    "室町時代",
    "安土桃山時代",
    "江戶時代",
    "明治時代",
    "大正時代",
    "昭和時代",
    "平成時代",
    "令和時代"
  ].freeze
  JAPAN_ROOT_PERIODS = ["倭", "日本", "大日本帝國"].freeze

  def run(argv)
    mode = argv.shift || "--dry-run"
    abort "Usage: ruby script/refine_atlas_regions_and_japan.rb [--dry-run|--apply]" unless %w[--dry-run --apply].include?(mode) && argv.empty?

    root = Pathname.new(__dir__).join("..").expand_path
    atlas_root = root.join("content", "atlas")
    periodisation_path = atlas_root.join("periodisation.json")
    abort "Not a typed Atlas tree: #{atlas_root}" unless atlas_root.join("entries").directory? && atlas_root.join("periods").directory?
    abort "Missing Atlas periodisation: #{periodisation_path}" unless periodisation_path.file?

    periodisation = read_json(periodisation_path)
    abort "Atlas periodisation must be a mapping" unless periodisation.is_a?(Hash)
    abort "This refinement expects typed periodisation version 2" unless periodisation["version"].to_i >= 2

    stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    report_dir = root.join("tmp", "atlas_region_refinement_#{stamp}")
    FileUtils.mkdir_p(report_dir)

    plan = build_plan(root, atlas_root, periodisation)
    write_plan(report_dir, plan)

    puts "Atlas macro-region/Japan refinement preview"
    puts "Mode:                    #{mode.sub('--', '')}"
    puts "Excluded corpus roots:   #{EXCLUDED_ROOTS.join(', ')}"
    puts "Macro-regions removed:   #{plan.fetch('removed_macro_regions').length}"
    puts "Japan periods to nest:   #{plan.fetch('japan_period_moves').count { |row| row['needed'] }}"
    puts "Other source cleanups:   #{plan.fetch('excluded_source_paths').count { |row| row['needed'] }}"
    puts "Actions still required:  #{plan.fetch('actions').count { |row| row['needed'] }}"
    puts "Report:                  #{report_dir}"

    return 0 if mode == "--dry-run"

    apply!(root, atlas_root, periodisation, plan, report_dir, stamp)
    puts
    puts "Applied Atlas macro-region/Japan refinement."
    puts "Run next:"
    puts "  bin/rails atlas:rebuild_catalogue"
    puts "  bin/rails atlas:verify"
    puts "  bin/rails runner script/atlas_region_policy_smoke.rb"
    0
  rescue JSON::ParserError => error
    warn "ERROR: invalid JSON: #{error.message}"
    1
  rescue StandardError => error
    warn "ERROR: #{error.class}: #{error.message}"
    warn error.backtrace.first(8).join("\n") if ENV["ATLAS_DEBUG"] == "1"
    1
  end

  def build_plan(root, atlas_root, periodisation)
    macro_regions = Array(periodisation["macro_regions"])
    removed_regions = macro_regions.select do |row|
      (Array(row["corpus_roots"]) & EXCLUDED_ROOTS).any?
    end
    removed_region_ids = removed_regions.map { |row| row["id"].to_s }

    actions = []
    actions << action("periodisation", "add excluded_corpus_roots", needed: (Array(periodisation["excluded_corpus_roots"]) | EXCLUDED_ROOTS) != Array(periodisation["excluded_corpus_roots"]))
    actions << action("periodisation", "remove macro-regions backed by 他漢文", needed: removed_regions.any?, detail: removed_region_ids.join(";"))

    japan = macro_regions.find { |row| row["id"].to_s == "日本" }
    abort "Missing 日本 macro-region in periodisation.json" unless japan
    actions << action("periodisation", "set 日本 root period groups", needed: Array(japan["period_ids"]) != JAPAN_ROOT_PERIODS, detail: JAPAN_ROOT_PERIODS.join(";"))

    japan_period_root = atlas_root.join("periods", "日本")
    group_metadata_path = japan_period_root.join("日本", "metadata.json")
    desired_group = japan_group_metadata
    group_needed = !group_metadata_path.file? || read_json(group_metadata_path) != desired_group
    actions << action("period", "create/update 日本 period group", needed: group_needed, path: relative(root, group_metadata_path))

    japan_moves = JAPAN_CHILD_PERIODS.each_with_index.map do |period, order|
      source_dir = japan_period_root.join(period)
      destination_dir = japan_period_root.join("日本", period)
      metadata_path = destination_dir.join("metadata.json")
      current_metadata = if metadata_path.file?
                           read_json(metadata_path)
                         elsif source_dir.join("metadata.json").file?
                           read_json(source_dir.join("metadata.json"))
                         end
      desired = current_metadata ? desired_child_metadata(current_metadata, period, order) : nil
      needed = source_dir.directory? || !destination_dir.directory? || current_metadata.nil? || current_metadata != desired
      actions << action("period", "nest #{period} under 日本", needed: needed, path: relative(root, destination_dir))
      {
        "period" => period,
        "source" => relative(root, source_dir),
        "destination" => relative(root, destination_dir),
        "needed" => needed,
        "metadata_present" => !current_metadata.nil?
      }
    end

    %w[倭 大日本帝國].each_with_index do |period, index|
      path = japan_period_root.join(period, "metadata.json")
      expected_order = period == "倭" ? 0 : 2
      desired_kind = period == "倭" ? "period_group" : nil
      needed = if path.file?
                 data = read_json(path)
                 data["order"].to_i != expected_order || (desired_kind && data["kind"].to_s != desired_kind)
               else
                 true
               end
      actions << action("period", "normalise #{period} root node", needed: needed, path: relative(root, path))
    end

    japan_entry = atlas_root.join("entries", "日本", "metadata.json")
    japan_entry_needed = if japan_entry.file?
                           data = read_json(japan_entry)
                           Array(data.dig("atlas", "period_ids")) != ["日本"] || data.dig("atlas", "periods")
                         else
                           false
                         end
    actions << action("entry", "assign 日本 polity to 日本 period group", needed: japan_entry_needed, path: relative(root, japan_entry))

    excluded_source_paths = []
    removed_region_ids.each do |region_id|
      path = atlas_root.join("periods", region_id)
      needed = path.exist?
      excluded_source_paths << { "path" => relative(root, path), "needed" => needed, "reason" => "macro-region backed by 他漢文" }
      actions << action("remove", "remove excluded period source tree", needed: needed, path: relative(root, path))
    end

    atlas_root.join("entries").glob("*/metadata.json").sort.each do |metadata_path|
      data = read_json(metadata_path)
      next unless EXCLUDED_ROOTS.include?(data.dig("corpus", "root").to_s)

      path = metadata_path.dirname
      excluded_source_paths << { "path" => relative(root, path), "needed" => true, "reason" => "polity sourced only from 他漢文" }
      actions << action("remove", "remove excluded polity source", needed: true, path: relative(root, path))
    end

    catalogue = root.join("storage", "corpus_search", "atlas", "catalogue-v4.json.gz")
    actions << action("generated", "remove stale catalogue-v4", needed: catalogue.file?, path: relative(root, catalogue))

    {
      "version" => 1,
      "generated_at" => Time.now.utc.iso8601,
      "excluded_corpus_roots" => EXCLUDED_ROOTS,
      "removed_macro_regions" => removed_region_ids,
      "japan_root_periods" => JAPAN_ROOT_PERIODS,
      "japan_period_moves" => japan_moves,
      "excluded_source_paths" => excluded_source_paths,
      "actions" => actions
    }
  end

  def apply!(root, atlas_root, periodisation, plan, report_dir, stamp)
    backup = root.join("tmp", "atlas_region_refinement_backup_#{stamp}")
    FileUtils.mkdir_p(backup)

    paths_to_backup = [atlas_root.join("periodisation.json"), atlas_root.join("periods", "日本"), atlas_root.join("entries", "日本")]
    plan.fetch("excluded_source_paths").each { |row| paths_to_backup << root.join(row.fetch("path")) }
    catalogue = root.join("storage", "corpus_search", "atlas", "catalogue-v4.json.gz")
    paths_to_backup << catalogue if catalogue.file?
    backup_paths!(root, backup, paths_to_backup.uniq)

    refine_periodisation!(periodisation)
    write_json(atlas_root.join("periodisation.json"), periodisation)

    refine_japan_periods!(atlas_root)
    refine_japan_entry!(atlas_root)
    remove_excluded_sources!(root, plan)
    FileUtils.rm_f(catalogue)

    verify_applied!(root, atlas_root)

    result = {
      "applied_at" => Time.now.utc.iso8601,
      "backup" => backup.to_s,
      "report" => report_dir.to_s,
      "routes_modified" => false
    }
    write_json(report_dir.join("applied.json"), result)
    puts "Backup:                  #{backup}"
  end

  def refine_periodisation!(periodisation)
    periodisation["excluded_corpus_roots"] = (Array(periodisation["excluded_corpus_roots"]) | EXCLUDED_ROOTS)
    periodisation["macro_regions"] = Array(periodisation["macro_regions"]).reject do |row|
      (Array(row["corpus_roots"]) & EXCLUDED_ROOTS).any?
    end
    japan = periodisation.fetch("macro_regions").find { |row| row["id"].to_s == "日本" }
    raise "Missing 日本 macro-region" unless japan
    japan["period_ids"] = JAPAN_ROOT_PERIODS.dup
  end

  def refine_japan_periods!(atlas_root)
    root = atlas_root.join("periods", "日本")
    group_dir = root.join("日本")
    FileUtils.mkdir_p(group_dir)

    JAPAN_CHILD_PERIODS.each_with_index do |period, order|
      source = root.join(period)
      destination = group_dir.join(period)
      if source.directory? && destination.directory?
        raise "Both old and new Japan period directories exist: #{source} and #{destination}"
      elsif source.directory?
        FileUtils.mkdir_p(destination.dirname)
        FileUtils.mv(source, destination)
      end

      metadata_path = destination.join("metadata.json")
      raise "Missing period metadata for #{period}: #{metadata_path}" unless metadata_path.file?
      data = read_json(metadata_path)
      write_json(metadata_path, desired_child_metadata(data, period, order))
    end

    write_json(group_dir.join("metadata.json"), japan_group_metadata)

    wa_path = root.join("倭", "metadata.json")
    raise "Missing 倭 period metadata" unless wa_path.file?
    wa = read_json(wa_path)
    wa["kind"] = "period_group"
    wa["parent_id"] = nil
    wa["order"] = 0
    write_json(wa_path, wa)

    empire_path = root.join("大日本帝國", "metadata.json")
    raise "Missing 大日本帝國 period metadata" unless empire_path.file?
    empire = read_json(empire_path)
    empire["parent_id"] = nil
    empire["order"] = 2
    write_json(empire_path, empire)
  end

  def refine_japan_entry!(atlas_root)
    path = atlas_root.join("entries", "日本", "metadata.json")
    return unless path.file?

    data = read_json(path)
    data["atlas"] = data.fetch("atlas", {}).to_h
    data["atlas"]["period_ids"] = ["日本"]
    data["atlas"].delete("periods")
    write_json(path, data)
  end

  def remove_excluded_sources!(root, plan)
    plan.fetch("excluded_source_paths").each do |row|
      next unless row["needed"]
      FileUtils.rm_rf(root.join(row.fetch("path")))
    end
  end

  def verify_applied!(root, atlas_root)
    periodisation = read_json(atlas_root.join("periodisation.json"))
    raise "他漢文 is not excluded" unless Array(periodisation["excluded_corpus_roots"]).include?("他漢文")
    if Array(periodisation["macro_regions"]).any? { |row| Array(row["corpus_roots"]).include?("他漢文") }
      raise "A 他漢文 macro-region remains"
    end

    japan = Array(periodisation["macro_regions"]).find { |row| row["id"].to_s == "日本" }
    raise "Japan root groups are wrong" unless Array(japan&.dig("period_ids")) == JAPAN_ROOT_PERIODS

    JAPAN_CHILD_PERIODS.each do |period|
      old_path = atlas_root.join("periods", "日本", period)
      new_metadata = atlas_root.join("periods", "日本", "日本", period, "metadata.json")
      raise "Old Japan period directory remains: #{old_path}" if old_path.exist?
      raise "Nested Japan period is missing: #{new_metadata}" unless new_metadata.file?
      data = read_json(new_metadata)
      raise "Wrong parent for #{period}" unless data["parent_id"] == "日本"
    end

    raise "Routes must not be modified by this script" unless root.join("config", "routes.rb").file?
  end

  def japan_group_metadata
    {
      "id" => "日本",
      "kind" => "period_group",
      "label" => "日本",
      "macro_region" => "日本",
      "parent_id" => nil,
      "order" => 1,
      "corpus_paths" => ["日本漢文/clean/日本"],
      "manifest_periods" => [],
      "aliases" => [],
      "hidden" => false,
      "legacy_entry_ids" => [],
      "article_path" => "periods/日本/日本/index.md"
    }
  end

  def desired_child_metadata(data, period, order)
    result = deep_dup(data)
    result["id"] = period
    result["kind"] = "period"
    result["macro_region"] = "日本"
    result["parent_id"] = "日本"
    result["order"] = order
    result["article_path"] = "periods/日本/日本/#{period}/index.md"
    result
  end

  def action(type, description, needed:, path: nil, detail: nil)
    {
      "type" => type,
      "description" => description,
      "path" => path,
      "detail" => detail,
      "needed" => needed
    }
  end

  def write_plan(report_dir, plan)
    write_json(report_dir.join("plan.json"), plan)
    CSV.open(report_dir.join("actions.csv"), "w", encoding: "UTF-8") do |csv|
      csv << %w[type description path detail needed]
      plan.fetch("actions").each do |row|
        csv << [row["type"], row["description"], row["path"], row["detail"], row["needed"]]
      end
    end
  end

  def backup_paths!(root, backup, paths)
    paths.each do |path|
      next unless path.exist?
      relative = path.relative_path_from(root)
      destination = backup.join(relative)
      FileUtils.mkdir_p(destination.dirname)
      FileUtils.cp_r(path, destination, preserve: true)
    end
  end

  def read_json(path)
    raw = path.binread.force_encoding(Encoding::UTF_8)
    raise "Invalid UTF-8: #{path}" unless raw.valid_encoding?
    JSON.parse(raw)
  end

  def write_json(path, value)
    FileUtils.mkdir_p(path.dirname)
    path.write(JSON.pretty_generate(value) + "\n", encoding: "UTF-8")
  end

  def relative(root, path)
    path.relative_path_from(root).to_s.tr("\\", "/")
  rescue ArgumentError
    path.to_s
  end

  def deep_dup(value)
    Marshal.load(Marshal.dump(value))
  end
end

exit AtlasRegionRefinement.run(ARGV)
