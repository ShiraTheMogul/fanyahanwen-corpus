#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "set"
require "time"
require "unicode_normalize/normalize"

# Renames work-directory components reported as unreadable by the corpus manifest.
# Full scholarly titles remain in metadata.json; only physical path components
# are shortened. The migration is plan-first and updates path strings in JSON.
class AuditedLongPathShortener
  SINGAPORE_COLLECTIONS = ["新加坡漢文/clean/名勝古跡", "新加坡漢文/clean/新洲雅苑懷舊集"].freeze
  DEFAULT_TITLE_CHARS = 36
  UNSAFE_COMPONENT_CHARS = /[<>:"\/\\|?*\u0000-\u001F]/.freeze
  RESERVED_WINDOWS_NAMES = /\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?\z/i.freeze

  def initialize(options)
    @corpus_root = Pathname(options.fetch(:corpus_root)).expand_path
    @audit_path = Pathname(options.fetch(:audit_path)).expand_path
    @id_registry_path = options[:id_registry] && Pathname(options[:id_registry]).expand_path
    @output_root = Pathname(options.fetch(:output_root)).expand_path
    @apply = options.fetch(:apply)
    @max_title_chars = Integer(options.fetch(:max_title_chars))
  end

  def run
    validate!
    FileUtils.mkdir_p(@output_root)
    @id_registry_path ||= discover_id_registry
    raise ArgumentError, "No metadata_id_registry.csv found; pass --id-registry PATH" unless @id_registry_path&.file?

    registry = load_registry
    plan = build_plan(registry)
    write_plan(plan)
    print_summary(plan)
    return unless @apply

    apply_plan(plan)
  end

  private

  def validate!
    raise ArgumentError, "Corpus root does not exist: #{@corpus_root}" unless @corpus_root.directory?
    raise ArgumentError, "Manifest audit does not exist: #{@audit_path}" unless @audit_path.file?
    raise ArgumentError, "--max-title-chars must be at least 12" if @max_title_chars < 12
  end

  def discover_id_registry
    candidates = Dir.glob(File.expand_path("tmp/corpus_metadata_json/full_*/metadata_id_registry.csv", Dir.pwd))
      .map { |path| Pathname(path) }
      .select(&:file?)
    candidates.max_by { |path| [path.mtime.to_i, path.to_s] }
  end

  def load_registry
    by_path = {}
    by_title = Hash.new { |hash, key| hash[key] = [] }
    count = 0

    CSV.foreach(@id_registry_path, headers: true, encoding: "bom|utf-8") do |row|
      next unless row["kind"].to_s == "work"

      id = Integer(row["id"], exception: false)
      path = normalize_rel(row["path"])
      title = row["title"].to_s.strip
      next unless id&.positive?

      record = { "work_id" => id, "path" => path, "title" => title }
      by_path[path] = record unless path.empty?
      by_title[title] << record unless title.empty?
      count += 1
      warn "[long-paths] registry work rows: #{count}" if (count % 10_000).zero?
    end

    { by_path: by_path, by_title: by_title, digest: Digest::SHA256.file(@id_registry_path).hexdigest }
  end

  def build_plan(registry)
    audit_rows = CSV.read(@audit_path, headers: true, encoding: "bom|utf-8")
      .select { |row| row["kind"].to_s == "unreadable_directory" }

    clean_plans_by_title = Hash.new { |hash, key| hash[key] = [] }
    rows = []

    # Clean paths have authoritative work-path entries in the ID registry.
    audit_rows.each do |row|
      old_rel = normalize_rel(row["path"])
      if SINGAPORE_COLLECTIONS.include?(old_rel)
        rows << skipped_row(old_rel, "folderise_flat_collection", "Handled by folderise_singapore_flat_collections.rb")
        next
      end
      next unless clean_path?(old_rel)

      record = registry.fetch(:by_path)[old_rel]
      unless record
        rows << skipped_row(old_rel, "registry_path_not_found", "No exact work path in metadata ID registry")
        next
      end

      planned = planned_row(old_rel, record)
      rows << planned
      clean_plans_by_title[File.basename(old_rel)] << planned
    end

    # Raw paths usually have no work metadata of their own. Pair them to the
    # corresponding clean path by the exact full legacy folder title.
    audit_rows.each do |row|
      old_rel = normalize_rel(row["path"])
      next unless raw_path?(old_rel)

      matches = clean_plans_by_title[File.basename(old_rel)]
      if matches.length != 1
        rows << skipped_row(old_rel, "raw_pair_ambiguous", "Expected one clean work with the same full folder title; found #{matches.length}")
        next
      end

      clean = matches.first
      target_rel = File.join(File.dirname(old_rel), File.basename(clean.fetch("new_path"))).tr("\\", "/")
      rows << {
        "status" => "planned",
        "role" => "raw_mirror",
        "work_id" => clean.fetch("work_id"),
        "title" => clean.fetch("title"),
        "old_path" => old_rel,
        "new_path" => target_rel,
        "old_component_bytes" => File.basename(old_rel).bytesize,
        "new_component_bytes" => File.basename(target_rel).bytesize,
        "reason" => "paired_to_clean_work"
      }
    end

    validate_plan_rows!(rows)

    {
      "version" => 1,
      "created_at" => Time.now.utc.iso8601,
      "corpus_root" => @corpus_root.to_s,
      "audit_path" => @audit_path.to_s,
      "audit_sha256" => Digest::SHA256.file(@audit_path).hexdigest,
      "id_registry" => @id_registry_path.to_s,
      "id_registry_sha256" => registry.fetch(:digest),
      "max_title_characters" => @max_title_chars,
      "rows" => rows
    }
  end

  def planned_row(old_rel, record)
    title = record.fetch("title").to_s.strip
    title = File.basename(old_rel) if title.empty?
    component = short_component(title, record.fetch("work_id"))
    new_rel = File.join(File.dirname(old_rel), component).tr("\\", "/")

    {
      "status" => "planned",
      "role" => "clean_work",
      "work_id" => record.fetch("work_id"),
      "title" => title,
      "old_path" => old_rel,
      "new_path" => new_rel,
      "old_component_bytes" => File.basename(old_rel).bytesize,
      "new_component_bytes" => component.bytesize,
      "reason" => "manifest_audit_unreadable_directory"
    }
  end

  def skipped_row(path, reason, message)
    {
      "status" => "skipped",
      "role" => "",
      "work_id" => "",
      "title" => File.basename(path),
      "old_path" => path,
      "new_path" => "",
      "old_component_bytes" => File.basename(path).bytesize,
      "new_component_bytes" => "",
      "reason" => "#{reason}: #{message}"
    }
  end

  def validate_plan_rows!(rows)
    planned = rows.select { |row| row["status"] == "planned" }
    duplicate_targets = planned.group_by { |row| row["new_path"] }.select { |_path, group| group.length > 1 }
    unless duplicate_targets.empty?
      raise ArgumentError, "Target-path collision(s): #{duplicate_targets.keys.join(', ')}"
    end

    planned.each do |row|
      old_abs = @corpus_root.join(row.fetch("old_path"))
      new_abs = @corpus_root.join(row.fetch("new_path"))
      row["source_exists"] = old_abs.exist?
      row["target_exists"] = new_abs.exist?
      row["blocked"] = !row["source_exists"] || row["target_exists"]
    rescue SystemCallError => error
      row["source_exists"] = "unknown"
      row["target_exists"] = "unknown"
      row["blocked"] = true
      row["reason"] = "#{row['reason']}; stat_failed=#{error.class}: #{error.message}"
    end
  end

  def apply_plan(plan)
    unless plan.fetch("audit_sha256") == Digest::SHA256.file(@audit_path).hexdigest
      raise ArgumentError, "Audit CSV changed after planning; rerun without --apply first"
    end
    unless plan.fetch("id_registry_sha256") == Digest::SHA256.file(@id_registry_path).hexdigest
      raise ArgumentError, "ID registry changed after planning; rerun without --apply first"
    end

    rows = plan.fetch("rows").select { |row| row["status"] == "planned" }
    blocked = rows.select { |row| row["blocked"] }
    raise ArgumentError, "#{blocked.length} planned rename(s) are blocked; review #{plan_csv_path}" unless blocked.empty?

    applied = []
    begin
      rows.each do |row|
        old_abs = @corpus_root.join(row.fetch("old_path"))
        new_abs = @corpus_root.join(row.fetch("new_path"))
        FileUtils.mkdir_p(new_abs.dirname)
        warn "[long-paths] rename #{row.fetch('old_path')} -> #{row.fetch('new_path')}"
        File.rename(old_abs, new_abs)
        applied << row
        update_metadata_paths(new_abs, row.fetch("old_path"), row.fetch("new_path")) if row["role"] == "clean_work"
      end
    rescue StandardError => error
      write_rollback(applied)
      raise error.class, "#{error.message}. Partial migration recorded in #{rollback_path}"
    end

    write_rollback(applied)
    @output_root.join("apply_summary.json").write(JSON.pretty_generate({
      "applied_at" => Time.now.utc.iso8601,
      "renamed_directories" => applied.length,
      "rollback_file" => rollback_path.to_s
    }) + "\n", encoding: "UTF-8")
    warn "[long-paths] applied #{applied.length} directory rename(s)"
  end

  def update_metadata_paths(directory, old_rel, new_rel)
    Dir.glob(directory.join("**", "metadata.json").to_s).each do |path_string|
      path = Pathname(path_string)
      payload = JSON.parse(path.read(encoding: "UTF-8"))
      changed = replace_prefixes(payload, old_rel, new_rel)
      next unless changed

      tmp = path.dirname.join(".metadata.json.#{$$}.tmp")
      tmp.write(JSON.pretty_generate(payload) + "\n", encoding: "UTF-8")
      File.rename(tmp, path)
    ensure
      FileUtils.rm_f(tmp) if defined?(tmp) && tmp
    end
  end

  def replace_prefixes(object, old_rel, new_rel)
    changed = false
    case object
    when Hash
      object.each do |key, value|
        if value.is_a?(String) && (value == old_rel || value.start_with?(old_rel + "/"))
          object[key] = new_rel + value.delete_prefix(old_rel)
          changed = true
        else
          changed = replace_prefixes(value, old_rel, new_rel) || changed
        end
      end
    when Array
      object.each_with_index do |value, index|
        if value.is_a?(String) && (value == old_rel || value.start_with?(old_rel + "/"))
          object[index] = new_rel + value.delete_prefix(old_rel)
          changed = true
        else
          changed = replace_prefixes(value, old_rel, new_rel) || changed
        end
      end
    end
    changed
  end

  def short_component(title, work_id)
    clean = title.to_s.unicode_normalize(:nfc)
      .gsub(UNSAFE_COMPONENT_CHARS, "-")
      .gsub(/[[:space:]]+/, " ")
      .strip
      .sub(/[. ]+\z/, "")
    clean = "work" if clean.empty? || clean.match?(RESERVED_WINDOWS_NAMES)
    graphemes = clean.each_grapheme_cluster.to_a
    clean = graphemes.first(@max_title_chars - 1).join + "…" if graphemes.length > @max_title_chars
    component = "#{clean}__w#{work_id}"
    raise ArgumentError, "Generated component exceeds 180 UTF-8 bytes: #{component}" if component.bytesize > 180
    component
  end

  def clean_path?(path)
    path.split("/").include?("clean")
  end

  def raw_path?(path)
    path.split("/").include?("raw")
  end

  def normalize_rel(value)
    value.to_s.tr("\\", "/").sub(%r{\A/+}, "").sub(%r{/+\z}, "")
  end

  def write_plan(plan)
    plan_path.write(JSON.pretty_generate(plan) + "\n", encoding: "UTF-8")
    rows = plan.fetch("rows")
    headers = rows.flat_map(&:keys).uniq
    CSV.open(plan_csv_path, "w", write_headers: true, headers: headers, encoding: "UTF-8") do |csv|
      rows.each { |row| csv << headers.map { |header| row[header] } }
    end
  end

  def write_rollback(applied)
    lines = applied.reverse.map do |row|
      "mv #{shell_quote(@corpus_root.join(row.fetch('new_path')).to_s)} #{shell_quote(@corpus_root.join(row.fetch('old_path')).to_s)}"
    end
    rollback_path.write(lines.join("\n") + "\n", encoding: "UTF-8")
  end

  def print_summary(plan)
    groups = plan.fetch("rows").group_by { |row| row["status"] }
    warn "[long-paths] planned=#{groups.fetch('planned', []).length} skipped=#{groups.fetch('skipped', []).length}"
    warn "[long-paths] review #{plan_csv_path}"
    warn "[long-paths] Singapore collection rows are intentionally delegated to the folderisation script"
  end

  def shell_quote(value)
    "'#{value.to_s.gsub("'", %q('"'"'))}'"
  end

  def plan_path = @output_root.join("plan.json")
  def plan_csv_path = @output_root.join("long_path_plan.csv")
  def rollback_path = @output_root.join("ROLLBACK.sh")
end

if $PROGRAM_NAME == __FILE__
  options = {
    corpus_root: ENV["CORPUS_ROOT"].to_s.empty? ? File.expand_path("../corpus", Dir.pwd) : ENV["CORPUS_ROOT"],
    audit_path: File.expand_path("tmp/corpus_search_manifest_audit/manifest_scan_issues.csv", Dir.pwd),
    id_registry: nil,
    output_root: File.expand_path("tmp/long_path_repair", Dir.pwd),
    apply: false,
    max_title_chars: AuditedLongPathShortener::DEFAULT_TITLE_CHARS
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: bundle exec ruby script/shorten_audited_long_paths.rb [options]"
    opts.on("--corpus-root PATH", "Live corpus root") { |value| options[:corpus_root] = value }
    opts.on("--audit PATH", "manifest_scan_issues.csv") { |value| options[:audit_path] = value }
    opts.on("--id-registry PATH", "Authoritative metadata_id_registry.csv") { |value| options[:id_registry] = value }
    opts.on("--output PATH", "Plan/report directory") { |value| options[:output_root] = value }
    opts.on("--max-title-chars N", Integer, "Physical title prefix length") { |value| options[:max_title_chars] = value }
    opts.on("--apply", "Apply reviewed directory renames") { options[:apply] = true }
    opts.on("-h", "--help") { puts opts; exit }
  end
  parser.parse!
  AuditedLongPathShortener.new(options).run
end
