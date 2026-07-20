# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"
require "pathname"
require "set"
require "time"

POLICIES = {
  ["中國", "商殷朝"] => ["all_children", %w[商甲骨文 商金文 甲骨文 金文 原不詳 未分類]],
  ["中國", "西周"] => ["all_children", %w[原不詳 未分類 西周金文 金文]],
  ["中國", "春秋"] => ["all_children", %w[原不詳 未分類 春秋金文 金文]],
  ["中國", "戰國"] => ["all_children", %w[原不詳 未分類 戰國金文 戰國簡牘 金文 簡牘]]
}.freeze

options = { apply: false }
OptionParser.new do |parser|
  parser.banner = "Usage: ruby script/repair_atlas_discovery_sources.rb [--dry-run|--apply]"
  parser.on("--dry-run") { options[:apply] = false }
  parser.on("--apply") { options[:apply] = true }
end.parse!

root = Pathname.new(__dir__).parent
atlas_root = root.join("content", "atlas")
period_paths = Dir.glob(atlas_root.join("periods", "**", "metadata.json").to_s).sort.map { |path| Pathname.new(path) }
entry_paths = Dir.glob(atlas_root.join("entries", "*", "metadata.json").to_s).sort.map { |path| Pathname.new(path) }

period_rows = period_paths.map do |path|
  raw = path.binread.force_encoding(Encoding::UTF_8)
  raise "Invalid UTF-8: #{path}" unless raw.valid_encoding?
  [path, JSON.parse(raw)]
end

period_terms = Set.new
period_rows.each do |_path, row|
  period_terms.merge([row["id"], row["label"], *Array(row["manifest_periods"]), *Array(row["aliases"])].compact.map(&:to_s))
end
periodisation = JSON.parse(atlas_root.join("periodisation.json").read(encoding: "UTF-8"))
Array(periodisation["macro_regions"]).each do |row|
  period_terms.merge([row["id"], row["label"], *Array(row["corpus_roots"])].compact.map(&:to_s))
end

changes = []
updated_payloads = {}

period_rows.each do |path, row|
  key = [row["macro_region"].to_s, row["id"].to_s]
  policy = POLICIES[key]
  policy ||= ["political_names", %w[未分類 原不詳]] if key.first == "日本" && row.fetch("kind", "period") == "period"
  next unless policy

  mode, exclusions = policy
  before = {
    "polity_discovery" => row["polity_discovery"],
    "excluded_polity_folders" => row["excluded_polity_folders"]
  }
  row["polity_discovery"] = mode
  row["excluded_polity_folders"] = exclusions
  after = {
    "polity_discovery" => row["polity_discovery"],
    "excluded_polity_folders" => row["excluded_polity_folders"]
  }
  next if before == after

  changes << {
    "kind" => "period_policy",
    "path" => path.relative_path_from(root).to_s,
    "before" => before,
    "after" => after
  }
  updated_payloads[path] = row
end

entry_paths.each do |path|
  raw = path.binread.force_encoding(Encoding::UTF_8)
  raise "Invalid UTF-8: #{path}" unless raw.valid_encoding?
  row = JSON.parse(raw)
  name = row["name"].is_a?(Hash) ? row["name"] : {}
  aliases = Array(name["alt"]).map(&:to_s)
  blocked = period_terms | Set.new(Array(row.dig("corpus", "periods")).map(&:to_s))
  blocked << name["display"].to_s
  blocked << name["hanzi"].to_s
  kept = aliases.reject do |value|
    value.empty? || blocked.include?(value) || value.include?("--") || value.include?("/") || value.include?("\\")
  end.uniq
  removed = aliases - kept
  next if removed.empty? && aliases == kept

  name["alt"] = kept
  row["name"] = name
  changes << {
    "kind" => "public_alias_cleanup",
    "path" => path.relative_path_from(root).to_s,
    "removed" => removed,
    "kept" => kept
  }
  updated_payloads[path] = row
end

stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
report_dir = root.join("tmp", "atlas_discovery_repair_#{stamp}")
report_dir.mkpath
report_dir.join("changes.json").write(JSON.pretty_generate(changes) + "\n", mode: "w", encoding: "UTF-8")

if options[:apply] && updated_payloads.any?
  backup_root = root.join("tmp", "atlas_discovery_repair_backup_#{stamp}")
  updated_payloads.each_key do |path|
    destination = backup_root.join(path.relative_path_from(root))
    destination.dirname.mkpath
    FileUtils.cp(path, destination)
  end
  updated_payloads.each do |path, row|
    path.write(JSON.pretty_generate(row) + "\n", mode: "w", encoding: "UTF-8")
  end
  puts "Backup: #{backup_root}"
end

puts "Atlas discovery/source repair #{options[:apply] ? 'apply' : 'preview'}"
puts "Period policies changed: #{changes.count { |row| row['kind'] == 'period_policy' }}"
puts "Entries with aliases cleaned: #{changes.count { |row| row['kind'] == 'public_alias_cleanup' }}"
puts "Aliases removed: #{changes.select { |row| row['kind'] == 'public_alias_cleanup' }.sum { |row| row['removed'].length }}"
puts "Report: #{report_dir}"
puts(options[:apply] ? "Applied." : "Run again with --apply after reviewing the report.")
