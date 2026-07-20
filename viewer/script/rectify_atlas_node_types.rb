#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# Reclassify the current Atlas source tree into explicit polity and period trees.
#
# This script is intentionally a migration, not a generator that guesses at
# request time. It operates over the Atlas tree produced by the earlier Atlas
# patches and is safe to run as a dry run first.
#
# Human-edited sources after migration:
#   content/atlas/entries/<polity>/...
#   content/atlas/periods/<macro-region>/<period>/...
#
# Generated runtime data remains under storage/corpus_search/atlas/.

require "csv"
require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "securerandom"
require "time"
require "unicode_normalize/normalize"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

module AtlasNodeTypeMigration
  module_function

  RULES_PATH = Pathname.new(__dir__).join("atlas_node_type_rules.json").freeze
  WINDOWS_FORBIDDEN = /[<>:"\/\\|?*\x00-\x1F]/
  WINDOWS_RESERVED = /\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?\z/i

  Options = Struct.new(:apply, :repo_root, keyword_init: true)
  EntryRecord = Struct.new(:dir, :metadata_path, :metadata, keyword_init: true)

  def run(argv)
    options = parse_options(argv)
    repo_root = Pathname.new(options.repo_root || Dir.pwd).expand_path
    atlas_root = repo_root.join("content", "atlas")
    entries_root = atlas_root.join("entries")
    periods_root = atlas_root.join("periods")

    abort_with("No Atlas entries directory found at #{entries_root}") unless entries_root.directory?
    rules = read_json!(RULES_PATH)
    entries = load_entries(entries_root)
    plan = build_plan(repo_root, atlas_root, entries, rules)

    print_summary(plan, apply: options.apply)
    report_dir = write_plan_report(repo_root, plan)
    puts "Plan report: #{report_dir}"

    unless options.apply
      puts
      puts "Dry run only: nothing was changed."
      puts "Run again with --apply after reviewing node_actions.csv and manual_review.csv."
      return 0
    end

    backup_root = create_backup!(repo_root, atlas_root)
    puts "Backup: #{backup_root}"

    preservation = capture_preservation_state(atlas_root)

    begin
      FileUtils.mkdir_p(periods_root)
      period_index = write_period_tree!(atlas_root, rules)
      migrate_merge_groups!(entries_root, period_index, rules.fetch("merge_polities"))
      migrate_converted_polities!(entries_root, rules.fetch("convert_polities"))
      migrate_period_only_entries!(entries_root, period_index, rules.fetch("period_only_entries"))
      rewrite_all_entry_metadata!(entries_root, period_index)
      rewrite_periodisation!(atlas_root, rules)
      remove_stale_generated_catalogue!(repo_root)
      verify_result!(atlas_root, rules, preservation)
    rescue StandardError => error
      warn
      warn "MIGRATION FAILED: #{error.class}: #{error.message}"
      warn "The untouched Atlas backup is at: #{backup_root}"
      warn "No automatic rollback was attempted."
      raise
    end

    puts
    puts "Atlas node-type migration complete."
    puts "Period sources: #{periods_root}"
    puts "Polity sources: #{entries_root}"
    puts
    puts "Next commands:"
    puts "  bin/rails atlas:rebuild_catalogue"
    puts "  bin/rails atlas:verify"
    puts "  ruby script/verify_unicode_integrity.rb"
    0
  end

  def parse_options(argv)
    options = Options.new(apply: false)
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby script/rectify_atlas_node_types.rb [--dry-run|--apply] [--repo PATH]"
      opts.on("--dry-run", "Write a complete plan without changing files (default)") { options.apply = false }
      opts.on("--apply", "Back up content/atlas, then perform the migration") { options.apply = true }
      opts.on("--repo PATH", "Viewer repository root; defaults to current directory") { |path| options.repo_root = path }
      opts.on("-h", "--help", "Show help") do
        puts opts
        exit 0
      end
    end
    parser.parse!(argv)
    abort_with("Unexpected arguments: #{argv.join(' ')}") unless argv.empty?
    options
  end

  def build_plan(repo_root, atlas_root, entries, rules)
    actions = []

    rules.fetch("merge_polities").each do |rule|
      source_names = rule.fetch("source_entry_names")
      sources = source_names.filter_map { |name| find_entry_by_folder(entries, name) }
      target = find_entry_by_folder(entries, rule.fetch("target_folder"))

      status = if sources.length == source_names.length
                 abort_with("Merge target already exists before migration: #{target.dir}") if target && !sources.include?(target)
                 "planned"
               elsif sources.empty? && target
                 "already_applied"
               else
                 found = sources.map { |row| row.dir.basename.to_s }
                 missing = source_names - found
                 abort_with("Partially applied merge for #{rule.fetch('target_folder')}: missing #{missing.join(', ')}")
               end

      actions << {
        "action" => "merge_period_entries_into_polity",
        "status" => status,
        "sources" => sources.map { |row| relative(repo_root, row.dir) },
        "source_ids" => sources.map { |row| row.metadata.fetch("id").to_s },
        "target" => relative(repo_root, atlas_root.join("entries", rule.fetch("target_folder"))),
        "target_name" => rule.fetch("target_folder"),
        "period_ids" => rule.fetch("period_ids")
      }
    end

    rules.fetch("convert_polities").each do |rule|
      source = find_entry_by_folder(entries, rule.fetch("source_entry_name"))
      target = find_entry_by_folder(entries, rule.fetch("target_folder"))
      status = if source
                 abort_with("Converted polity target already exists before migration: #{target.dir}") if target && target != source
                 "planned"
               elsif target
                 "already_applied"
               else
                 abort_with("Neither source nor target exists for converted polity #{rule.fetch('source_entry_name')}")
               end

      actions << {
        "action" => "rename_period_named_polity",
        "status" => status,
        "sources" => source ? [relative(repo_root, source.dir)] : [],
        "source_ids" => source ? [source.metadata.fetch("id").to_s] : [],
        "target" => relative(repo_root, atlas_root.join("entries", rule.fetch("target_folder"))),
        "target_name" => rule.fetch("target_folder"),
        "period_ids" => rule.fetch("period_ids")
      }
    end

    rules.fetch("period_only_entries").each do |name|
      source = find_entry_by_folder(entries, name)
      period_exists = period_source_exists?(atlas_root, rules, name)
      status = if source
                 "planned"
               elsif period_exists
                 "already_applied"
               else
                 abort_with("Neither polity-style source nor typed period exists for #{name}")
               end

      actions << {
        "action" => "move_entry_to_period_tree",
        "status" => status,
        "sources" => source ? [relative(repo_root, source.dir)] : [],
        "source_ids" => source ? [source.metadata.fetch("id").to_s] : [],
        "target" => period_target_for_rule(rules, name),
        "target_name" => name,
        "period_ids" => [name]
      }
    end

    period_nodes = flatten_period_rules(rules)
    planned = actions.select { |row| row.fetch("status") == "planned" }
    merge_reduction = planned.select { |row| row.fetch("action") == "merge_period_entries_into_polity" }
      .sum { |row| row.fetch("sources").length - 1 }
    period_reduction = planned.count { |row| row.fetch("action") == "move_entry_to_period_tree" }

    {
      "version" => 2,
      "created_at" => Time.now.utc.iso8601,
      "entry_count_before" => entries.length,
      "period_node_count" => period_nodes.length,
      "actions" => actions,
      "planned_action_count" => planned.length,
      "already_applied_action_count" => actions.length - planned.length,
      "manual_review" => rules.fetch("manual_review_entries"),
      "expected_entry_count_after" => entries.length - merge_reduction - period_reduction,
      "period_tree" => period_nodes.map do |node|
        {
          "macro_region" => node.fetch("macro_region"),
          "id" => node.fetch("id"),
          "label" => node.fetch("label"),
          "parent_id" => node["parent_id"],
          "corpus_paths" => node.fetch("corpus_paths", []),
          "manifest_periods" => node.fetch("manifest_periods", []),
          "hidden" => node["hidden"] == true
        }
      end
    }
  end

  def period_source_exists?(atlas_root, rules, id)
    row = flatten_period_rules(rules).find { |node| node.fetch("id") == id }
    return false unless row

    period_dir_for_rule(atlas_root, rules, row).join("metadata.json").file?
  end

  def period_dir_for_rule(atlas_root, rules, row)
    region = row.fetch("macro_region")
    by_key = flatten_period_rules(rules).to_h { |node| [[node.fetch("macro_region"), node.fetch("id")], node] }
    chain = []
    current = row
    while current
      chain.unshift(current.fetch("id"))
      parent_id = current["parent_id"]
      current = parent_id ? by_key[[region, parent_id]] : nil
    end
    atlas_root.join("periods", region, *chain)
  end

  def print_summary(plan, apply:)
    puts "=" * 76
    puts "ATLAS NODE-TYPE MIGRATION — #{apply ? 'APPLY' : 'DRY RUN'}"
    puts "=" * 76
    puts "Current polity-style entries: #{plan.fetch('entry_count_before')}"
    puts "Typed period nodes:           #{plan.fetch('period_node_count')}"
    puts "Source-tree actions:          #{plan.fetch('actions').length}"
    puts "Actions still to apply:       #{plan.fetch('planned_action_count')}"
    puts "Actions already applied:      #{plan.fetch('already_applied_action_count')}"
    puts "Expected polity entries:      #{plan.fetch('expected_entry_count_after')}"
    puts "Manual-review entries:        #{plan.fetch('manual_review').length}"
    puts
    puts "This migration preserves corpus paths such as 中國漢文/clean/... exactly."
    puts "Only Atlas macro-region labels use 中國, 日本, 朝鮮, and so forth."
  end

  def write_plan_report(repo_root, plan)
    stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    dir = repo_root.join("tmp", "atlas_node_type_migration_#{stamp}")
    FileUtils.mkdir_p(dir)
    write_utf8(dir.join("plan.json"), JSON.pretty_generate(plan) + "\n")

    CSV.open(dir.join("node_actions.csv"), "wb", encoding: "UTF-8") do |csv|
      csv << %w[action status source_ids sources target target_name period_ids]
      plan.fetch("actions").each do |row|
        csv << [
          row.fetch("action"),
          row.fetch("status"),
          row.fetch("source_ids").join(" | "),
          row.fetch("sources").join(" | "),
          row.fetch("target"),
          row.fetch("target_name"),
          row.fetch("period_ids").join(" | ")
        ]
      end
    end

    CSV.open(dir.join("period_tree.csv"), "wb", encoding: "UTF-8") do |csv|
      csv << %w[macro_region id label parent_id corpus_paths manifest_periods hidden]
      plan.fetch("period_tree").each do |row|
        csv << [
          row.fetch("macro_region"), row.fetch("id"), row.fetch("label"), row["parent_id"],
          row.fetch("corpus_paths").join(" | "), row.fetch("manifest_periods").join(" | "), row.fetch("hidden")
        ]
      end
    end

    CSV.open(dir.join("manual_review.csv"), "wb", encoding: "UTF-8") do |csv|
      csv << %w[name reason]
      plan.fetch("manual_review").each { |row| csv << [row.fetch("name"), row.fetch("reason")] }
    end
    dir
  end

  def create_backup!(repo_root, atlas_root)
    stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    backup_root = repo_root.join("tmp", "atlas_typed_backup_#{stamp}")
    abort_with("Backup path already exists: #{backup_root}") if backup_root.exist?
    FileUtils.mkdir_p(backup_root)
    FileUtils.cp_r(atlas_root, backup_root.join("atlas"), preserve: true)
    backup_root
  end

  def load_entries(entries_root)
    paths = Dir.glob(entries_root.join("*", "metadata.json").to_s).sort
    abort_with("No immediate entry metadata files found under #{entries_root}") if paths.empty?
    paths.map do |filename|
      path = Pathname.new(filename)
      EntryRecord.new(dir: path.dirname, metadata_path: path, metadata: read_json!(path))
    end
  end

  def entry_lookup(entries)
    lookup = Hash.new { |hash, key| hash[key] = [] }
    entries.each do |entry|
      names = [
        entry.dir.basename.to_s,
        entry.metadata["id"],
        entry.metadata.dig("name", "display"),
        entry.metadata.dig("name", "hanzi"),
        entry.metadata.dig("corpus", "polity"),
        *Array(entry.metadata.dig("name", "alt"))
      ].compact.map(&:to_s).map(&:strip).reject(&:empty?).uniq
      names.each { |name| lookup[name] << entry }
    end
    lookup
  end

  def find_entry!(lookup, name)
    rows = lookup[name.to_s]
    abort_with("Atlas entry was not found for rule #{name.inspect}") if rows.nil? || rows.empty?
    exact = rows.select { |row| row.dir.basename.to_s == name.to_s }
    rows = exact if exact.any?
    abort_with("Atlas entry rule #{name.inspect} matched more than one folder") if rows.length != 1
    rows.first
  end

  def find_entry_by_folder(entries, name)
    entries.find { |entry| entry.dir.basename.to_s == name.to_s }
  end

  def write_period_tree!(atlas_root, rules)
    periods_root = atlas_root.join("periods")
    index = {}
    rules.fetch("macro_regions").each do |region|
      region_id = region.fetch("id")
      Array(region["periods"]).each_with_index do |node, order|
        write_period_node!(
          periods_root: periods_root,
          region_id: region_id,
          node: node,
          parent_id: nil,
          parent_dir: periods_root.join(region_id),
          order: order,
          index: index
        )
      end
    end
    index
  end

  def write_period_node!(periods_root:, region_id:, node:, parent_id:, parent_dir:, order:, index:)
    id = node.fetch("id").to_s
    validate_folder_name!(id)
    dir = parent_dir.join(id)
    FileUtils.mkdir_p(dir)
    metadata_path = dir.join("metadata.json")
    previous = metadata_path.file? ? read_json!(metadata_path) : {}

    metadata = {
      "id" => id,
      "kind" => node.fetch("kind", "period"),
      "label" => node.fetch("label", id),
      "macro_region" => region_id,
      "parent_id" => parent_id,
      "order" => order,
      "corpus_paths" => Array(node["corpus_paths"]).map(&:to_s),
      "manifest_periods" => Array(node["manifest_periods"]).map(&:to_s),
      "aliases" => Array(node["aliases"]).map(&:to_s),
      "hidden" => node["hidden"] == true,
      "legacy_entry_ids" => Array(previous["legacy_entry_ids"]).map(&:to_s),
      "article_path" => dir.join("index.md").relative_path_from(periods_root.parent).to_s.tr("\\", "/")
    }

    # Preserve research fields added manually to an existing period source.
    %w[timespan locations rulers notable_authors notable_works related historical notes].each do |key|
      metadata[key] = previous[key] if previous.key?(key)
    end

    atomic_write_json(metadata_path, metadata)
    key = [region_id, id]
    raise "Duplicate period ID inside macro-region: #{key.join(' / ')}" if index.key?(key)
    index[key] = { dir: dir, metadata_path: metadata_path, metadata: metadata }

    Array(node["children"]).each_with_index do |child, child_order|
      write_period_node!(
        periods_root: periods_root,
        region_id: region_id,
        node: child,
        parent_id: id,
        parent_dir: dir,
        order: child_order,
        index: index
      )
    end
  end

  def migrate_merge_groups!(entries_root, period_index, rules)
    rules.each do |rule|
      entries = load_entries(entries_root)
      source_names = rule.fetch("source_entry_names")
      sources = source_names.filter_map { |name| find_entry_by_folder(entries, name) }
      target_dir = entries_root.join(rule.fetch("target_folder"))
      validate_folder_name!(target_dir.basename.to_s)

      if sources.empty? && target_dir.directory?
        puts "Already applied: #{source_names.join(' + ')} → #{target_dir.basename}"
        next
      end
      if sources.length != source_names.length
        found = sources.map { |row| row.dir.basename.to_s }
        missing = source_names - found
        raise "Partially applied merge for #{target_dir.basename}: missing #{missing.join(', ')}"
      end
      unrelated_target = target_dir.directory? && sources.none? { |source| source.dir == target_dir }
      raise "Merge target already exists: #{target_dir}" if unrelated_target

      source_names.zip(sources, rule.fetch("period_ids")).each do |_name, source, period_id|
        period = find_period!(period_index, source.metadata, period_id)
        preserve_period_article_files!(source.dir, period.fetch(:dir))
        add_period_legacy_id!(period, source.metadata.fetch("id").to_s)
        merge_period_research_fields!(period, source.metadata)
      end

      merged = merged_polity_metadata(sources.map(&:metadata), rule)
      staging = entries_root.join(".__atlas_typed_merge__#{SecureRandom.hex(6)}")
      FileUtils.mkdir_p(staging)
      atomic_write_json(staging.join("metadata.json"), merged)

      sources.each do |source|
        source.dir.children.each do |child|
          next if child.basename.to_s == "metadata.json"
          next if child.basename.to_s.match?(/\Aindex(?:\.[a-z0-9_-]+)?\.md\z/i)
          merge_file_or_directory!(child, staging.join(child.basename))
        end
      end

      sources.each { |source| FileUtils.rm_rf(source.dir) }
      FileUtils.mv(staging, target_dir)
      rewrite_entry_article_path!(target_dir)
    end
  end

  def migrate_converted_polities!(entries_root, rules)
    rules.each do |rule|
      entries = load_entries(entries_root)
      source = find_entry_by_folder(entries, rule.fetch("source_entry_name"))
      target_dir = entries_root.join(rule.fetch("target_folder"))
      validate_folder_name!(target_dir.basename.to_s)

      if source.nil? && target_dir.directory?
        puts "Already applied: #{rule.fetch('source_entry_name')} → #{target_dir.basename}"
        next
      end
      raise "Converted polity source is missing: #{rule.fetch('source_entry_name')}" unless source
      if target_dir.exist? && target_dir != source.dir
        raise "Converted polity target already exists: #{target_dir}"
      end

      metadata = deep_dup(source.metadata)
      metadata["kind"] = "polity"
      metadata["name"] ||= {}
      metadata["name"]["display"] = rule.fetch("display")
      metadata["name"]["hanzi"] = rule.fetch("hanzi")
      metadata["name"]["alt"] = stable_union(
        Array(metadata.dig("name", "alt")),
        Array(rule["aliases"]),
        [source.dir.basename.to_s]
      ).reject { |value| value == rule.fetch("hanzi") || value == rule.fetch("display") }
      metadata["corpus"] ||= {}
      metadata["corpus"]["polity"] = rule.fetch("corpus_polity")
      metadata["atlas"] ||= {}
      metadata["atlas"]["period_ids"] = Array(rule.fetch("period_ids"))

      FileUtils.mv(source.dir, target_dir) if source.dir != target_dir
      atomic_write_json(target_dir.join("metadata.json"), metadata)
      rewrite_entry_article_path!(target_dir)
    end
  end

  def migrate_period_only_entries!(entries_root, period_index, names)
    names.each do |name|
      entries = load_entries(entries_root)
      source = find_entry_by_folder(entries, name)
      period = period_index.values.find { |row| row.fetch(:metadata).fetch("id") == name }
      raise "No period node was prepared for #{name}" unless period

      unless source
        puts "Already applied: #{name} is a typed period"
        next
      end

      preserve_period_article_files!(source.dir, period.fetch(:dir))
      add_period_legacy_id!(period, source.metadata.fetch("id").to_s)
      merge_period_research_fields!(period, source.metadata)
      FileUtils.rm_rf(source.dir)
    end
  end

  def merged_polity_metadata(source_rows, rule)
    first = deep_dup(source_rows.first)
    ids = source_rows.map { |row| row.fetch("id").to_s }
    first["id"] = rule.fetch("target_id")
    first["kind"] = "polity"
    first["name"] ||= {}
    first["name"]["display"] = rule.fetch("display")
    first["name"]["hanzi"] = rule.fetch("hanzi")
    first["name"]["alt"] = stable_union(
      source_rows.flat_map { |row| Array(row.dig("name", "alt")) },
      source_rows.flat_map { |row| [row.dig("name", "display"), row.dig("name", "hanzi"), row.dig("corpus", "polity")] },
      source_rows.map { |row| row.fetch("id").to_s }
    ).reject { |value| value == rule.fetch("display") || value == rule.fetch("hanzi") }

    first["corpus"] ||= {}
    first["corpus"]["root"] = source_rows.map { |row| row.dig("corpus", "root").to_s }.reject(&:empty?).uniq.first.to_s
    first["corpus"]["polity"] = rule.fetch("corpus_polity")
    first["corpus"]["periods"] = Array(rule.fetch("period_ids"))
    first["corpus"]["paths"] = stable_union(source_rows.flat_map { |row| Array(row.dig("corpus", "paths")) })
    first["atlas"] ||= {}
    first["atlas"]["period_ids"] = Array(rule.fetch("period_ids"))
    first["legacy_ids"] = stable_union(source_rows.flat_map { |row| Array(row["legacy_ids"]) })

    %w[notable_authors notable_works rulers related].each do |key|
      first[key] = stable_union(source_rows.flat_map { |row| Array(row[key]) })
    end
    first["locations"] = merge_hashes(source_rows.map { |row| row["locations"] })
    first["historical"] = merge_hashes(source_rows.map { |row| row["historical"] })
    first["notes"] = stable_union(source_rows.map { |row| row["notes"].to_s }.reject(&:empty?)).join("\n\n")
    first["article_path"] = "entries/#{rule.fetch('target_folder')}/index.md"
    first
  end

  def merge_hashes(values)
    hashes = values.select { |value| value.is_a?(Hash) }
    keys = hashes.flat_map(&:keys).uniq
    keys.each_with_object({}) do |key, merged|
      present = hashes.map { |hash| hash[key] }.compact
      next if present.empty?
      merged[key] = if present.any? { |value| value.is_a?(Array) }
                      stable_union(present.flat_map { |value| Array(value) })
                    elsif present.any? { |value| value.is_a?(Hash) }
                      merge_hashes(present)
                    else
                      present.find { |value| !value.to_s.empty? }
                    end
    end
  end

  def preserve_period_article_files!(source_dir, period_dir)
    source_dir.children.each do |child|
      next unless child.file? && child.basename.to_s.match?(/\Aindex(?:\.[a-z0-9_-]+)?\.md\z/i)
      target = period_dir.join(child.basename)
      if target.file?
        unless Digest::SHA256.file(target).hexdigest == Digest::SHA256.file(child).hexdigest
          raise "Different period articles would collide: #{child} -> #{target}"
        end
        child.delete
      else
        FileUtils.mv(child, target)
      end
    end
  end

  def add_period_legacy_id!(period, legacy_id)
    metadata = read_json!(period.fetch(:metadata_path))
    metadata["legacy_entry_ids"] = stable_union(Array(metadata["legacy_entry_ids"]), [legacy_id])
    atomic_write_json(period.fetch(:metadata_path), metadata)
    period[:metadata] = metadata
  end

  def merge_period_research_fields!(period, source_metadata)
    metadata = read_json!(period.fetch(:metadata_path))
    %w[timespan locations rulers notable_authors notable_works related historical notes].each do |key|
      next unless source_metadata.key?(key)
      if metadata[key].nil? || metadata[key] == "" || metadata[key] == [] || metadata[key] == {}
        metadata[key] = deep_dup(source_metadata[key])
      elsif metadata[key].is_a?(Array) || source_metadata[key].is_a?(Array)
        metadata[key] = stable_union(Array(metadata[key]), Array(source_metadata[key]))
      elsif metadata[key].is_a?(Hash) && source_metadata[key].is_a?(Hash)
        metadata[key] = merge_hashes([metadata[key], source_metadata[key]])
      end
    end
    atomic_write_json(period.fetch(:metadata_path), metadata)
    period[:metadata] = metadata
  end

  def rewrite_all_entry_metadata!(entries_root, period_index)
    load_entries(entries_root).each do |entry|
      metadata = deep_dup(entry.metadata)
      metadata["kind"] = "polity"
      metadata["article_path"] = "entries/#{entry.dir.basename}/index.md"
      metadata["atlas"] ||= {}
      explicit = Array(metadata.dig("atlas", "period_ids")).map(&:to_s).reject(&:empty?)
      if explicit.empty?
        region = infer_entry_region(metadata)
        explicit = match_period_ids(period_index, region, metadata)
      end
      metadata["atlas"]["period_ids"] = explicit.uniq
      atomic_write_json(entry.metadata_path, metadata)
    end
  end

  def infer_entry_region(metadata)
    root = metadata.dig("corpus", "root").to_s
    return nil if %w[他漢文 西域漢文].include?(root)

    {
      "中國漢文" => "中國", "日本漢文" => "日本", "朝鮮漢文" => "朝鮮",
      "琉球漢文" => "琉球", "越南漢文" => "越南",
      "新加坡漢文" => "新加坡"
    }[root] || Array(metadata.dig("atlas", "macro_regions")).first.to_s
  end

  def match_period_ids(period_index, region, metadata)
    paths = Array(metadata.dig("corpus", "paths")).map(&:to_s)
    manifest_periods = Array(metadata.dig("corpus", "periods")).map(&:to_s)
    direct = period_index.filter_map do |(node_region, id), row|
      next unless node_region == region
      node = row.fetch(:metadata)
      path_match = Array(node["corpus_paths"]).any? do |prefix|
        paths.any? { |path| path == prefix || path.start_with?(prefix + "/") }
      end
      period_match = (Array(node["manifest_periods"]) & manifest_periods).any?
      id if path_match || period_match
    end
    with_period_ancestors(period_index, region, direct)
  end

  def with_period_ancestors(period_index, region, ids)
    result = []
    ids.each do |id|
      current = id
      while current && !current.to_s.empty?
        result << current unless result.include?(current)
        row = period_index[[region, current]]
        current = row&.fetch(:metadata, {})&.fetch("parent_id", nil)
      end
    end
    result.reverse.uniq
  end

  def rewrite_periodisation!(atlas_root, rules)
    payload = {
      "version" => 2,
      "macro_regions" => rules.fetch("macro_regions").map do |region|
        {
          "id" => region.fetch("id"),
          "label" => region.fetch("label"),
          "corpus_roots" => Array(region["corpus_roots"]),
          "period_ids" => Array(region["periods"]).map { |node| node.fetch("id") }
        }
      end
    }
    atomic_write_json(atlas_root.join("periodisation.json"), payload)
  end

  def remove_stale_generated_catalogue!(repo_root)
    # Schema v3 writes to a new cache path. Removing an old v2 file prevents a
    # human from mistaking it for the current generated source of truth.
    old = repo_root.join("storage", "corpus_search", "atlas", "catalogue-v2.json.gz")
    FileUtils.rm_f(old) if old.file?
  end

  def capture_preservation_state(atlas_root)
    article_hashes = Dir.glob(atlas_root.join("**", "index*.md").to_s).map do |path|
      Digest::SHA256.file(path).hexdigest
    end.tally
    references = Dir.glob(atlas_root.join("entries", "*", "metadata.json").to_s).flat_map do |path|
      metadata_reference_strings(read_json!(Pathname.new(path)))
    end.tally
    ids = Dir.glob(atlas_root.join("entries", "*", "metadata.json").to_s).map do |path|
      read_json!(Pathname.new(path)).fetch("id").to_s
    end
    { article_hashes: article_hashes, references: references, ids: ids }
  end

  def verify_result!(atlas_root, rules, preservation)
    entries = load_entries(atlas_root.join("entries"))
    expected = rules.fetch("macro_regions").sum do |region|
      count_period_nodes(Array(region["periods"]))
    end
    period_paths = Dir.glob(atlas_root.join("periods", "**", "metadata.json").to_s)
    raise "Expected #{expected} period nodes; found #{period_paths.length}" unless period_paths.length == expected

    bad_kinds = entries.reject { |entry| entry.metadata.fetch("kind", "polity") == "polity" }
    raise "Non-polity records remain under entries/: #{bad_kinds.map { |row| row.dir.basename }.join(', ')}" if bad_kinds.any?

    forbidden = rules.fetch("period_only_entries") + rules.fetch("merge_polities").flat_map { |row| row.fetch("source_entry_names") }
    remaining = entries.map { |entry| entry.dir.basename.to_s } & forbidden
    raise "Period folders remain under entries/: #{remaining.join(', ')}" if remaining.any?

    all_json = Dir.glob(atlas_root.join("**", "*.json").to_s)
    all_json.each { |path| read_json!(Pathname.new(path)) }

    after_hashes = Dir.glob(atlas_root.join("**", "index*.md").to_s).map do |path|
      Digest::SHA256.file(path).hexdigest
    end.tally
    preservation.fetch(:article_hashes).each do |hash, count|
      raise "An Atlas article was lost or altered during migration: #{hash}" if after_hashes[hash].to_i < count
    end

    after_references = Dir.glob(atlas_root.join("**", "metadata.json").to_s).flat_map do |path|
      metadata_reference_strings(read_json!(Pathname.new(path)))
    end.tally
    preservation.fetch(:references).each do |reference, count|
      raise "A metadata reference was lost during migration: #{reference}" if after_references[reference].to_i < count
    end

    aliases = entries.flat_map do |entry|
      [entry.metadata.fetch("id").to_s, *Array(entry.metadata["legacy_ids"]).map(&:to_s)]
    end
    aliases.concat(period_paths.flat_map do |path|
      metadata = read_json!(Pathname.new(path))
      Array(metadata["legacy_entry_ids"]).map(&:to_s)
    end)
    missing_ids = preservation.fetch(:ids) - aliases
    raise "Old Atlas IDs were not preserved: #{missing_ids.join(', ')}" if missing_ids.any?

    verify_utf8_tree!(atlas_root)
    true
  end

  def metadata_reference_strings(value, parent_key = nil)
    case value
    when Hash
      value.flat_map { |key, child| metadata_reference_strings(child, key.to_s) }
    when Array
      value.flat_map { |child| metadata_reference_strings(child, parent_key) }
    when String
      parent_key == "references" ? [value] : []
    else
      []
    end
  end

  def verify_utf8_tree!(root)
    root.find do |path|
      relative = path.relative_path_from(root).to_s
      raise "Replacement character in Atlas path: #{relative}" if relative.include?("\uFFFD")
      relative.encode(Encoding::UTF_8)
      next unless path.file? && %w[.json .md .yml .yaml .rb .csv .txt].include?(path.extname.downcase)
      raw = path.binread.force_encoding(Encoding::UTF_8)
      raise "Invalid UTF-8: #{path}" unless raw.valid_encoding?
      raise "Replacement character in Atlas text: #{path}" if raw.include?("\uFFFD")
    end
  end

  def flatten_period_rules(rules)
    rows = []
    rules.fetch("macro_regions").each do |region|
      Array(region["periods"]).each_with_index do |node, order|
        flatten_period_node(rows, region.fetch("id"), node, nil, order)
      end
    end
    rows
  end

  def flatten_period_node(rows, region_id, node, parent_id, order)
    row = deep_dup(node)
    row["macro_region"] = region_id
    row["parent_id"] = parent_id
    row["order"] = order
    rows << row
    Array(node["children"]).each_with_index do |child, child_order|
      flatten_period_node(rows, region_id, child, node.fetch("id"), child_order)
    end
  end

  def period_target_for_rule(rules, id)
    row = flatten_period_rules(rules).find { |node| node.fetch("id") == id }
    row ? "content/atlas/periods/#{row.fetch('macro_region')}/.../#{id}" : "MISSING PERIOD RULE"
  end

  def find_period!(period_index, source_metadata, id)
    region = infer_entry_region(source_metadata)
    period_index.fetch([region, id]) do
      raise "No period node #{region} / #{id} was prepared"
    end
  end

  def rewrite_entry_article_path!(entry_dir)
    metadata_path = entry_dir.join("metadata.json")
    metadata = read_json!(metadata_path)
    metadata["article_path"] = "entries/#{entry_dir.basename}/index.md"
    atomic_write_json(metadata_path, metadata)
  end

  def merge_file_or_directory!(source, target)
    if source.directory?
      if target.exist? && !target.directory?
        raise "Directory/file collision: #{source} -> #{target}"
      end
      FileUtils.mkdir_p(target)
      source.children.each { |child| merge_file_or_directory!(child, target.join(child.basename)) }
      FileUtils.rm_rf(source)
    elsif target.file?
      unless Digest::SHA256.file(source).hexdigest == Digest::SHA256.file(target).hexdigest
        raise "Different files would collide: #{source} -> #{target}"
      end
      source.delete
    else
      FileUtils.mv(source, target)
    end
  end

  def stable_union(*arrays)
    seen = {}
    arrays.flatten.compact.each_with_object([]) do |value, result|
      next if value.respond_to?(:empty?) && value.empty?
      key = value.is_a?(String) ? value : JSON.generate(value)
      next if seen[key]
      seen[key] = true
      result << deep_dup(value)
    end
  end

  def count_period_nodes(nodes)
    Array(nodes).sum { |node| 1 + count_period_nodes(node["children"]) }
  end

  def validate_folder_name!(value)
    name = value.to_s.unicode_normalize(:nfc)
    unsafe = name.empty? || name == "." || name == ".." || name.match?(WINDOWS_FORBIDDEN) ||
      name.match?(WINDOWS_RESERVED) || name.end_with?(" ", ".")
    raise "Unsafe Atlas folder name: #{name.inspect}" if unsafe
    name
  end

  def read_json!(path)
    raw = path.binread.force_encoding(Encoding::UTF_8)
    raise "Invalid UTF-8 JSON: #{path}" unless raw.valid_encoding?
    parsed = JSON.parse(raw)
    raise "JSON root must be an object: #{path}" unless parsed.is_a?(Hash)
    parsed
  rescue JSON::ParserError => error
    raise "Invalid JSON in #{path}: #{error.message}"
  end

  def atomic_write_json(path, value)
    FileUtils.mkdir_p(path.dirname)
    temp = path.dirname.join(".#{path.basename}.tmp-#{Process.pid}-#{SecureRandom.hex(4)}")
    write_utf8(temp, JSON.pretty_generate(value) + "\n")
    File.rename(temp, path)
  ensure
    FileUtils.rm_f(temp) if defined?(temp) && temp&.exist?
  end

  def write_utf8(path, content)
    File.open(path, "wb") { |file| file.write(content.to_s.encode(Encoding::UTF_8)) }
  end

  def deep_dup(value)
    Marshal.load(Marshal.dump(value))
  end

  def relative(root, path)
    Pathname.new(path).relative_path_from(Pathname.new(root)).to_s.tr("\\", "/")
  end

  def abort_with(message)
    warn "ERROR: #{message}"
    exit 1
  end
end

exit AtlasNodeTypeMigration.run(ARGV) if $PROGRAM_NAME == __FILE__
