#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

# One-time migration for the Fanya Hanwen Atlas source tree.
#
# What this changes:
#   content/atlas/entries/polity-.../  -> content/atlas/entries/實際名稱/
#
# What this deliberately does NOT change:
#   corpus.root and corpus.paths values such as 中國漢文/clean/...
#
# Those are real corpus folder names. They identify Literary Chinese corpus
# collections and must remain exact so manifest joins and search links work.

require "csv"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "securerandom"
require "time"
require "unicode_normalize/normalize"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

module AtlasLayoutMigration
  module_function

  ROOT_TO_MACRO_REGION = {
    "中國漢文" => "中國",
    "日本漢文" => "日本",
    "朝鮮漢文" => "朝鮮",
    "琉球漢文" => "琉球",
    "越南漢文" => "越南",
    "西域漢文" => "西域"
  }.freeze

  OBSOLETE_DIRECTORIES = %w[
    polities
    states
  ].freeze

  OBSOLETE_FILES = %w[
    hierarchy.json
    entry_path_migration.json
    catalogue-v2.json
  ].freeze

  WINDOWS_FORBIDDEN = /[<>:"\/\\|?*\x00-\x1F]/
  WINDOWS_RESERVED = /\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?\z/i

  EntryPlan = Struct.new(
    :source_dir,
    :target_dir,
    :metadata,
    :metadata_path,
    :target_name,
    keyword_init: true
  )

  Options = Struct.new(:apply, :repo_root, keyword_init: true)

  def run(argv)
    options = parse_options(argv)
    repo_root = Pathname.new(options.repo_root || Dir.pwd).expand_path
    atlas_root = repo_root.join("content", "atlas")
    entries_root = atlas_root.join("entries")

    abort_with("No Atlas source tree found at #{atlas_root}") unless atlas_root.directory?
    abort_with("No Atlas entries directory found at #{entries_root}") unless entries_root.directory?

    plans = load_plans(entries_root)
    validate_plans!(plans)
    report = build_report(repo_root, atlas_root, plans)

    print_summary(report, apply: options.apply)
    write_report(repo_root, report)

    unless options.apply
      puts
      puts "Dry run only: nothing was changed."
      puts "Run again with --apply after reviewing the report."
      return 0
    end

    backup_root = create_backup!(repo_root, atlas_root)
    puts "Backup: #{backup_root}"

    begin
      apply_entry_renames!(plans, entries_root)
      rewrite_entry_metadata!(entries_root)
      normalise_periodisation!(atlas_root.join("periodisation.json"))
      remove_obsolete_sources!(atlas_root)
      verify_result!(atlas_root, plans.length)
    rescue StandardError => error
      warn
      warn "MIGRATION FAILED: #{error.class}: #{error.message}"
      warn "The untouched backup is at: #{backup_root}"
      warn "No automatic rollback was attempted, because copying the backup over a"
      warn "partially changed OneDrive tree could destroy useful evidence."
      raise
    end

    puts
    puts "Atlas source layout migration complete."
    puts "Next commands:"
    puts "  bin/rails atlas:rebuild_catalogue"
    puts "  bin/rails atlas:verify"
    puts "  ruby script/verify_unicode_integrity.rb"
    0
  end

  def parse_options(argv)
    options = Options.new(apply: false)

    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby script/normalise_atlas_layout.rb [--dry-run|--apply] [--repo PATH]"

      opts.on("--dry-run", "Show the exact migration plan without changing files (default)") do
        options.apply = false
      end

      opts.on("--apply", "Create a backup, then perform the migration") do
        options.apply = true
      end

      opts.on("--repo PATH", "Viewer repository root; defaults to the current directory") do |path|
        options.repo_root = path
      end

      opts.on("-h", "--help", "Show this help") do
        puts opts
        exit 0
      end
    end

    parser.parse!(argv)
    abort_with("Unexpected arguments: #{argv.join(' ')}") unless argv.empty?
    options
  end

  def load_plans(entries_root)
    metadata_paths = Dir.glob(entries_root.join("*", "metadata.json").to_s).sort
    abort_with("No metadata.json files found immediately below #{entries_root}") if metadata_paths.empty?

    metadata_paths.map do |filename|
      metadata_path = Pathname.new(filename)
      metadata = read_json!(metadata_path)
      target_name = display_folder_name(metadata, metadata_path)

      EntryPlan.new(
        source_dir: metadata_path.dirname,
        target_dir: entries_root.join(target_name),
        metadata: metadata,
        metadata_path: metadata_path,
        target_name: target_name
      )
    end
  end

  def display_folder_name(metadata, metadata_path)
    name = metadata.fetch("name", {})

    # Prefer the corpus polity value because it is already the canonical folder
    # label used by the manifest. This matters for entries such as Shang, where
    # the article may display 商方 but the polity itself is filed as 商, and for
    # 薛／邳, where the display slash cannot be used in a directory name.
    candidate = metadata.dig("corpus", "polity").to_s.strip
    candidate = name["hanzi"].to_s.strip if candidate.empty?
    candidate = name["display"].to_s.strip if candidate.empty?
    candidate = metadata["id"].to_s.strip if candidate.empty?
    candidate = candidate.unicode_normalize(:nfc)

    abort_with("No usable display name in #{metadata_path}") if candidate.empty?
    abort_with("Unsafe Atlas folder name #{candidate.inspect} in #{metadata_path}") if unsafe_folder_name?(candidate)
    candidate
  end

  def unsafe_folder_name?(value)
    value == "." || value == ".." ||
      value.match?(WINDOWS_FORBIDDEN) ||
      value.match?(WINDOWS_RESERVED) ||
      value.end_with?(" ", ".")
  end

  def validate_plans!(plans)
    duplicate_targets = plans.group_by { |plan| windows_key(plan.target_name) }
      .select { |_key, rows| rows.length > 1 }

    unless duplicate_targets.empty?
      details = duplicate_targets.values.map do |rows|
        rows.map { |row| "#{row.target_name} (#{row.metadata['id']})" }.join(", ")
      end
      abort_with("Atlas folder-name collisions:\n  #{details.join("\n  ")}")
    end

    duplicate_ids = plans.group_by { |plan| plan.metadata.fetch("id").to_s }
      .select { |_id, rows| rows.length > 1 }
    abort_with("Duplicate Atlas IDs: #{duplicate_ids.keys.join(', ')}") if duplicate_ids.any?

    plans.each do |plan|
      next if plan.source_dir == plan.target_dir
      next unless plan.target_dir.exist?

      abort_with(
        "Target already exists before migration: #{plan.target_dir}\n" \
        "Source was: #{plan.source_dir}\n" \
        "Resolve this manually rather than allowing an automatic merge."
      )
    end
  end

  def windows_key(value)
    value.unicode_normalize(:nfc).downcase
  end

  def build_report(repo_root, atlas_root, plans)
    renames = plans.reject { |plan| plan.source_dir == plan.target_dir }.map do |plan|
      {
        "id" => plan.metadata.fetch("id").to_s,
        "name" => plan.target_name,
        "from" => relative(repo_root, plan.source_dir),
        "to" => relative(repo_root, plan.target_dir),
        "article_exists" => plan.source_dir.join("index.md").file?
      }
    end

    removals = []
    OBSOLETE_DIRECTORIES.each do |name|
      path = atlas_root.join(name)
      removals << relative(repo_root, path) if path.exist?
    end
    OBSOLETE_FILES.each do |name|
      path = atlas_root.join(name)
      removals << relative(repo_root, path) if path.exist?
    end

    {
      "version" => 1,
      "created_at" => Time.now.utc.iso8601,
      "entry_count" => plans.length,
      "rename_count" => renames.length,
      "unchanged_folder_count" => plans.length - renames.length,
      "renames" => renames,
      "obsolete_paths_to_remove" => removals,
      "macro_region_normalisation" => ROOT_TO_MACRO_REGION,
      "preserved_corpus_root_values" => ROOT_TO_MACRO_REGION.keys
    }
  end

  def print_summary(report, apply:)
    puts "=" * 72
    puts "ATLAS SOURCE LAYOUT MIGRATION — #{apply ? 'APPLY' : 'DRY RUN'}"
    puts "=" * 72
    puts "Entries found:          #{report.fetch('entry_count')}"
    puts "Folders to rename:      #{report.fetch('rename_count')}"
    puts "Folders already human:  #{report.fetch('unchanged_folder_count')}"
    puts "Obsolete paths to axe:  #{report.fetch('obsolete_paths_to_remove').length}"
    puts
    puts "Macro-region values become:"
    ROOT_TO_MACRO_REGION.each { |root, region| puts "  #{root} -> #{region}" }
    puts
    puts "Corpus roots and corpus search paths keep 漢文. They are not macro-regions."
  end

  def write_report(repo_root, report)
    stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    report_dir = repo_root.join("tmp", "atlas_layout_migration_#{stamp}")
    FileUtils.mkdir_p(report_dir)

    write_utf8(report_dir.join("plan.json"), JSON.pretty_generate(report) + "\n")

    CSV.open(report_dir.join("renames.csv"), "wb", encoding: "UTF-8") do |csv|
      csv << %w[id name from to article_exists]
      report.fetch("renames").each do |row|
        csv << [row["id"], row["name"], row["from"], row["to"], row["article_exists"]]
      end
    end

    write_utf8(
      report_dir.join("obsolete_paths.txt"),
      report.fetch("obsolete_paths_to_remove").join("\n") + "\n"
    )

    puts "Plan report: #{report_dir}"
  end

  def create_backup!(repo_root, atlas_root)
    stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    backup_root = repo_root.join("tmp", "atlas_source_backup_#{stamp}")
    abort_with("Backup path already exists: #{backup_root}") if backup_root.exist?

    FileUtils.mkdir_p(backup_root)
    FileUtils.cp_r(atlas_root, backup_root.join("atlas"), preserve: true)
    backup_root
  end

  def apply_entry_renames!(plans, entries_root)
    move_plans = plans.reject { |plan| plan.source_dir == plan.target_dir }
    staged = []

    # First move every changing directory to a temporary ASCII name. This avoids
    # collisions where one desired name happens to be another entry's old name.
    move_plans.each_with_index do |plan, index|
      staging = entries_root.join(".__atlas_migration__#{index}_#{SecureRandom.hex(5)}")
      raise "Unexpected staging collision: #{staging}" if staging.exist?

      File.rename(plan.source_dir, staging)
      staged << [plan, staging]
    end

    staged.each do |plan, staging|
      raise "Target appeared during migration: #{plan.target_dir}" if plan.target_dir.exist?
      File.rename(staging, plan.target_dir)
    end
  end

  def rewrite_entry_metadata!(entries_root)
    Dir.glob(entries_root.join("*", "metadata.json").to_s).sort.each do |filename|
      path = Pathname.new(filename)
      metadata = read_json!(path)
      name = display_folder_name(metadata, path)

      unless path.dirname.basename.to_s == name
        raise "Folder/metadata mismatch: #{path.dirname.basename} != #{name}"
      end

      metadata["article_path"] = "entries/#{name}/index.md"
      metadata.delete("placements")
      normalise_metadata_macro_regions!(metadata)
      atomic_write_json(path, metadata)
    end
  end

  def normalise_metadata_macro_regions!(metadata)
    if metadata.key?("macro_region")
      metadata["macro_region"] = normalise_macro_region(metadata["macro_region"])
    end

    if metadata["macro_regions"].is_a?(Array)
      metadata["macro_regions"] = metadata["macro_regions"].map { |value| normalise_macro_region(value) }.uniq
    end

    atlas = metadata["atlas"]
    if atlas.is_a?(Hash) && atlas["macro_regions"].is_a?(Array)
      atlas["macro_regions"] = atlas["macro_regions"].map { |value| normalise_macro_region(value) }.uniq
    end
  end

  def normalise_macro_region(value)
    candidate = value.to_s.strip
    ROOT_TO_MACRO_REGION.fetch(candidate, candidate)
  end

  def normalise_periodisation!(path)
    payload = read_json!(path)
    regions = payload.fetch("macro_regions")
    raise "periodisation.json macro_regions must be a list" unless regions.is_a?(Array)

    regions.each do |row|
      old_id = row.fetch("id").to_s
      new_id = normalise_macro_region(old_id)
      row["id"] = new_id

      label = row["label"].to_s
      ROOT_TO_MACRO_REGION.each do |corpus_root, macro_region|
        label = label.gsub(corpus_root, macro_region)
      end
      row["label"] = label.empty? ? new_id : label

      # Important: corpus_roots are deliberately untouched.
      row["corpus_roots"] = Array(row["corpus_roots"]).map(&:to_s).uniq
    end

    duplicate_ids = regions.group_by { |row| row.fetch("id") }.select { |_id, rows| rows.length > 1 }
    raise "Duplicate macro-regions after normalisation: #{duplicate_ids.keys.join(', ')}" if duplicate_ids.any?

    atomic_write_json(path, payload)
  end

  def remove_obsolete_sources!(atlas_root)
    OBSOLETE_DIRECTORIES.each do |name|
      path = atlas_root.join(name)
      FileUtils.rm_rf(path) if path.exist?
    end

    OBSOLETE_FILES.each do |name|
      path = atlas_root.join(name)
      FileUtils.rm_f(path) if path.exist?
    end
  end

  def verify_result!(atlas_root, expected_entries)
    entries_root = atlas_root.join("entries")
    metadata_paths = Dir.glob(entries_root.join("*", "metadata.json").to_s).sort
    raise "Expected #{expected_entries} entries after migration; found #{metadata_paths.length}" unless metadata_paths.length == expected_entries

    metadata_paths.each do |filename|
      path = Pathname.new(filename)
      metadata = read_json!(path)
      expected_name = display_folder_name(metadata, path)
      actual_name = path.dirname.basename.to_s
      raise "Non-human entry folder remains: #{actual_name}" unless actual_name == expected_name

      expected_article = "entries/#{expected_name}/index.md"
      raise "Wrong article_path for #{actual_name}" unless metadata["article_path"] == expected_article
      raise "Obsolete placements remain in #{path}" if metadata.key?("placements")
    end

    OBSOLETE_DIRECTORIES.each do |name|
      raise "Obsolete directory still exists: #{name}" if atlas_root.join(name).exist?
    end
    OBSOLETE_FILES.each do |name|
      raise "Obsolete file still exists: #{name}" if atlas_root.join(name).exist?
    end

    periodisation = read_json!(atlas_root.join("periodisation.json"))
    ids = periodisation.fetch("macro_regions").map { |row| row.fetch("id") }
    forbidden = ids & ROOT_TO_MACRO_REGION.keys
    raise "Corpus-root names still used as macro-regions: #{forbidden.join(', ')}" if forbidden.any?

    true
  end

  def read_json!(path)
    raw = path.binread.force_encoding(Encoding::UTF_8)
    raise "Invalid UTF-8: #{path}" unless raw.valid_encoding?
    JSON.parse(raw)
  rescue JSON::ParserError => error
    raise "Invalid JSON in #{path}: #{error.message}"
  end

  def atomic_write_json(path, payload)
    atomic_write(path, JSON.pretty_generate(payload) + "\n")
  end

  def atomic_write(path, text)
    text = text.encode(Encoding::UTF_8)
    temp = path.dirname.join(".#{path.basename}.#{$$}.#{SecureRandom.hex(4)}.tmp")
    temp.binwrite(text)
    File.rename(temp, path)
  ensure
    FileUtils.rm_f(temp) if defined?(temp) && temp
  end

  def write_utf8(path, text)
    path.binwrite(text.encode(Encoding::UTF_8))
  end

  def relative(root, path)
    Pathname.new(path).relative_path_from(root).to_s.tr("\\", "/")
  rescue ArgumentError
    path.to_s
  end

  def abort_with(message)
    warn "ERROR: #{message}"
    exit 1
  end
end

exit AtlasLayoutMigration.run(ARGV)
