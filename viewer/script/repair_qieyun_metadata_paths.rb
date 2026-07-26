#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"
require "time"

DEFAULT_RELATIVE_PATH = "中國漢文/clean/隋朝/切韻"

options = {
  corpus_root: File.expand_path("../corpus", __dir__ + "/.."),
  relative_path: DEFAULT_RELATIVE_PATH,
  apply: false
}

OptionParser.new do |parser|
  parser.banner = "Usage: ruby script/repair_qieyun_metadata_paths.rb [options]"
  parser.on("--corpus-root PATH", "Corpus root (default: ../corpus)") { |value| options[:corpus_root] = value }
  parser.on("--relative-path PATH", "切韻 work path inside corpus") { |value| options[:relative_path] = value }
  parser.on("--apply", "Write corrected paths to metadata.json") { options[:apply] = true }
end.parse!

corpus_root = Pathname(options[:corpus_root]).expand_path
work_root = corpus_root.join(options[:relative_path])
metadata_path = work_root.join("metadata.json")

abort "Missing metadata: #{metadata_path}" unless metadata_path.file?

metadata = JSON.parse(metadata_path.read(encoding: "UTF-8"))
changes = []

Array(metadata["editions"]).each do |edition|
  edition_label = edition["edition_label"].to_s
  Array(edition["documents"]).each do |document|
    source_file = document["file"].to_s
    abort "Blank document file in #{edition_label}" if source_file.empty?

    matches = work_root.glob("**/#{source_file}").select(&:file?)
    abort "No installed file named #{source_file} beneath #{work_root}" if matches.empty?
    abort "More than one installed file named #{source_file}: #{matches.join(', ')}" if matches.length > 1

    actual_path = matches.first.relative_path_from(corpus_root).to_s.tr("\\", "/")
    old_path = document["path"].to_s.tr("\\", "/")
    next if old_path == actual_path

    changes << {
      edition_label: edition_label,
      source_file: source_file,
      old_path: old_path,
      new_path: actual_path
    }
    document["path"] = actual_path
  end
end

puts "QIEYUN METADATA PATH REPAIR — #{options[:apply] ? 'APPLY' : 'DRY RUN'}"
puts "================================================================"
puts "Metadata: #{metadata_path}"
puts "Changes:  #{changes.length}"
changes.each do |change|
  puts
  puts "#{change.fetch(:edition_label)}"
  puts "  old: #{change.fetch(:old_path)}"
  puts "  new: #{change.fetch(:new_path)}"
end

if changes.empty?
  puts
  puts "Already correct. No write needed."
  exit 0
end

unless options[:apply]
  puts
  puts "DRY-RUN READY"
  puts "No files were changed. Rerun with --apply."
  exit 0
end

timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
backup = metadata_path.sub_ext(".json.before_qieyun_path_repair_#{timestamp}")
backup.binwrite(metadata_path.binread)

temporary = metadata_path.sub_ext(".json.tmp")
temporary.write(JSON.pretty_generate(metadata) + "\n", encoding: "UTF-8")
temporary.rename(metadata_path)

puts
puts "METADATA PATH REPAIR COMPLETE"
puts "Backup: #{backup}"
