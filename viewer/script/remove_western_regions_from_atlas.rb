#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"
require "pathname"
require "rbconfig"
require "time"

# Removes the accidental empty 西域 / Western Regions Atlas branch without
# renaming or deleting the real 西域漢文 corpus root.
#
# Dry-run is the default. This script touches only:
#   content/atlas/periodisation.json
#   script/atlas_node_type_rules.json
#   script/rectify_atlas_node_types.rb (only the periodisation writer)
#
# It never edits routes, corpus files, articles, periods, or the database.
module RemoveWesternRegionsFromAtlas
  module_function

  TARGET_REGION_ID = "西域"
  TARGET_CORPUS_ROOT = "西域漢文"

  def run(argv)
    options = { apply: false, repo_root: Pathname.pwd }
    OptionParser.new do |parser|
      parser.banner = "Usage: ruby script/remove_western_regions_from_atlas.rb [--dry-run|--apply] [--repo PATH]"
      parser.on("--dry-run", "Report changes only (default)") { options[:apply] = false }
      parser.on("--apply", "Write the reviewed JSON changes") { options[:apply] = true }
      parser.on("--repo PATH", "Viewer root (default: current directory)") { |value| options[:repo_root] = Pathname.new(value) }
      parser.on("-h", "--help", "Show this help") { puts parser; return 0 }
    end.parse!(argv)

    root = options.fetch(:repo_root).expand_path
    json_files = [
      root.join("content", "atlas", "periodisation.json"),
      root.join("script", "atlas_node_type_rules.json")
    ]
    rectifier_path = root.join("script", "rectify_atlas_node_types.rb")
    required_files = json_files + [rectifier_path]
    missing = required_files.reject(&:file?)
    abort "Missing required files:\n  #{missing.join("\n  ")}" if missing.any?

    plans = json_files.map { |path| plan_for(path, root) }
    rectifier_plan = plan_rectifier(rectifier_path, root)
    period_dir = root.join("content", "atlas", "periods", TARGET_REGION_ID)

    puts "Western Regions Atlas removal"
    puts "============================="
    puts "Mode: #{options[:apply] ? 'APPLY' : 'DRY RUN'}"
    puts
    plans.each { |plan| print_plan(plan) }
    print_rectifier_plan(rectifier_plan)
    if rectifier_plan.fetch(:blocked)
      puts "REVIEW REQUIRED: the rectifier method did not match the known safe pattern."
      puts "No files were changed."
      return 2
    end
    if period_dir.exist?
      puts "REVIEW REQUIRED: #{period_dir.relative_path_from(root)} exists."
      puts "The script will not delete period/article material automatically."
      return 2
    end

    if plans.none? { |plan| plan.fetch(:changed) } && !rectifier_plan.fetch(:changed)
      puts "No changes needed: the unwanted macro-region is already absent and #{TARGET_CORPUS_ROOT} is excluded."
      return 0
    end

    unless options[:apply]
      puts
      puts "Dry run only: nothing changed."
      puts "Run again with --apply after reviewing this output."
      return 0
    end

    stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    backup_root = root.join("tmp", "atlas_western_regions_removal", stamp)
    plans.each do |plan|
      next unless plan.fetch(:changed)

      path = plan.fetch(:path)
      backup_file(path, root, backup_root)
      atomic_write_json(path, plan.fetch(:after))
    end
    if rectifier_plan.fetch(:changed)
      path = rectifier_plan.fetch(:path)
      backup_file(path, root, backup_root)
      atomic_write_text(path, rectifier_plan.fetch(:after))
    end

    # Read the written files again so a partial or malformed write cannot pass.
    json_files.each { |path| JSON.parse(path.read(encoding: "UTF-8")) }
    ruby_ok = system(RbConfig.ruby, "-c", rectifier_path.to_s, out: File::NULL)
    raise "Rectifier syntax check failed after write" unless ruby_ok

    puts
    puts "Applied. Backups: #{backup_root}"
    puts "Next commands:"
    puts "  bin/rails atlas:rebuild_catalogue"
    puts "  bin/rails atlas:verify"
    puts "  ruby script/project_state_audit.rb --corpus-root ../corpus --scope 維基大典/clean --max-files 1000 --output tmp/project_state_audit/wiki_clean_1000"
    0
  rescue JSON::ParserError => error
    warn "Invalid JSON: #{error.message}"
    2
  end

  def plan_for(path, root)
    before = JSON.parse(path.read(encoding: "UTF-8"))
    after = deep_copy(before)
    regions = Array(after["macro_regions"])
    removed = regions.select { |row| western_region?(row) }
    after["macro_regions"] = regions.reject { |row| western_region?(row) }

    excluded = Array(after["excluded_corpus_roots"]).map(&:to_s).reject(&:empty?)
    excluded << TARGET_CORPUS_ROOT
    after["excluded_corpus_roots"] = excluded.uniq

    {
      path: path,
      relative: path.relative_path_from(root).to_s.tr("\\", "/"),
      before: before,
      after: after,
      removed: removed,
      added_exclusion: !Array(before["excluded_corpus_roots"]).map(&:to_s).include?(TARGET_CORPUS_ROOT),
      changed: before != after
    }
  end

  def western_region?(row)
    row.is_a?(Hash) && (
      row["id"].to_s == TARGET_REGION_ID ||
      row["label"].to_s.include?("Western Regions") ||
      Array(row["corpus_roots"]).map(&:to_s).include?(TARGET_CORPUS_ROOT)
    )
  end

  def print_plan(plan)
    puts plan.fetch(:relative)
    puts "  macro-regions removed: #{plan.fetch(:removed).length}"
    puts "  add #{TARGET_CORPUS_ROOT} to excluded_corpus_roots: #{plan.fetch(:added_exclusion)}"
    puts "  file would change: #{plan.fetch(:changed)}"
  end

  def plan_rectifier(path, root)
    before = path.read(encoding: "UTF-8")
    if before.match?(/"excluded_corpus_roots"\s*=>\s*Array\(rules\["excluded_corpus_roots"\]\)/)
      after = before
      blocked = false
    else
      marker = %(      "version" => 2,\n)
      method_start = before.index("  def rewrite_periodisation!(atlas_root, rules)\n")
      marker_index = method_start && before.index(marker, method_start)
      method_end = method_start && before.index("\n  end\n", method_start)
      if marker_index && method_end && marker_index < method_end
        addition = %(      "excluded_corpus_roots" => Array(rules["excluded_corpus_roots"]).map(&:to_s).reject(&:empty?).uniq,\n)
        after = before.dup.insert(marker_index + marker.length, addition)
        blocked = false
      else
        after = before
        blocked = true
      end
    end

    {
      path: path,
      relative: path.relative_path_from(root).to_s.tr("\\", "/"),
      before: before,
      after: after,
      changed: before != after,
      blocked: blocked
    }
  end

  def print_rectifier_plan(plan)
    puts plan.fetch(:relative)
    puts "  preserve excluded_corpus_roots when regenerating periodisation: #{plan.fetch(:changed)}"
    puts "  safe patch pattern found: #{!plan.fetch(:blocked)}"
  end

  def backup_file(path, root, backup_root)
    relative = path.relative_path_from(root)
    backup = backup_root.join(relative)
    FileUtils.mkdir_p(backup.dirname)
    FileUtils.cp(path, backup)
  end

  def atomic_write_text(path, text)
    temporary = path.sub_ext("#{path.extname}.tmp-#{Process.pid}")
    temporary.write(text, encoding: "UTF-8")
    File.rename(temporary, path)
  ensure
    FileUtils.rm_f(temporary) if temporary&.exist?
  end

  def deep_copy(value)
    JSON.parse(JSON.generate(value))
  end

  def atomic_write_json(path, payload)
    temporary = path.sub_ext("#{path.extname}.tmp-#{Process.pid}")
    temporary.write(JSON.pretty_generate(payload) + "\n", encoding: "UTF-8")
    File.rename(temporary, path)
  ensure
    FileUtils.rm_f(temporary) if temporary&.exist?
  end
end

exit RemoveWesternRegionsFromAtlas.run(ARGV)
