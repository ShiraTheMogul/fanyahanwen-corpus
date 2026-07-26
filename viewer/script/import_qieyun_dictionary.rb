#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "time"

require_relative "../config/environment"
require Rails.root.join("lib/dictionary_import/qieyun_reconstruction_dataset").to_s
require Rails.root.join("app/services/importers/qieyun_reconstruction_importer").to_s

options = {
  corpus_root: Rails.root.join("..", "corpus").to_s,
  relative_path: DictionaryImport::QieyunReconstructionDataset::DEFAULT_RELATIVE_PATH,
  output: Rails.root.join("tmp", "dictionary_import", "qieyun_reconstructions_#{Time.now.utc.strftime('%Y%m%dT%H%M%SZ')}").to_s,
  apply: false,
  replace: false,
  log_every: 500
}

OptionParser.new do |parser|
  parser.banner = "Usage: ruby script/import_qieyun_dictionary.rb [options]"
  parser.on("--corpus-root PATH", "Corpus root (default: ../corpus)") { |value| options[:corpus_root] = value }
  parser.on("--relative-path PATH", "切韻 path inside the corpus") { |value| options[:relative_path] = value }
  parser.on("--output PATH", "Dry-run report directory") { |value| options[:output] = value }
  parser.on("--apply", "Write the parsed dictionary to the current Rails database") { options[:apply] = true }
  parser.on("--replace", "Replace an existing 切韻 DictionaryWork with a changed fingerprint") { options[:replace] = true }
  parser.on("--log-every N", Integer, "Progress interval during import") { |value| options[:log_every] = value }
end.parse!

output = Pathname(options[:output]).expand_path
FileUtils.rm_rf(output)
FileUtils.mkdir_p(output)

dataset = DictionaryImport::QieyunReconstructionDataset.new(
  corpus_root: options[:corpus_root],
  relative_path: options[:relative_path]
).load!

summary = dataset.summary.merge(
  "created_at" => Time.now.utc.iso8601,
  "corpus_root" => Pathname(options[:corpus_root]).expand_path.to_s,
  "relative_path" => options[:relative_path],
  "database_writes" => options[:apply] ? "requested" : 0,
  "corpus_writes" => 0
)
output.join("summary.json").write(JSON.pretty_generate(summary) + "\n", encoding: "UTF-8")

CSV.open(output.join("editions.csv"), "w", write_headers: true, headers: %w[edition_id edition_label document_id sections entries groups source_path]) do |csv|
  dataset.editions.each do |edition|
    csv << [
      edition.fetch("edition_id"),
      edition.fetch("edition_label"),
      edition.fetch("document_id"),
      edition.fetch("section_count"),
      edition.fetch("entry_count"),
      edition.fetch("group_count"),
      edition.fetch("source_path")
    ]
  end
end

CSV.open(output.join("sections.csv"), "w", write_headers: true, headers: %w[sequence edition_id edition_label tone rhyme label document_id]) do |csv|
  dataset.sections.each do |section|
    csv << [
      section.fetch("sequence_number"),
      section.fetch("edition_id"),
      section.fetch("edition_label"),
      section.fetch("tone_section"),
      section.fetch("rhyme_heading"),
      section.fetch("label"),
      section.fetch("document_id")
    ]
  end
end

sample = dataset.entries.first(25) + dataset.entries.last(25)
output.join("entry_sample.json").write(JSON.pretty_generate(sample) + "\n", encoding: "UTF-8")

puts <<~REPORT
  QIEYUN RECONSTRUCTION DICTIONARY — #{options[:apply] ? 'IMPORT' : 'DRY RUN'}
  ============================================================================
  Corpus work ID:          #{dataset.work_id}
  Dictionary:              #{dataset.title}
  Reconstructed editions:  #{dataset.editions.length}
  Sections:                #{dataset.sections.length}
  Entries:                 #{dataset.entries.length}
  Small-rime groups:       #{dataset.entries.count { |entry| entry.fetch('group_head') }}
  Fanqie readings:         #{dataset.entries.sum { |entry| entry.fetch('fanqie').length }}
  Character links:         #{dataset.entries.count { |entry| dataset.linkable_headword?(entry.fetch('headword')) }}
  Unresolved markers:      #{dataset.entries.count { |entry| entry.fetch('contains_unresolved_glyph') }}
  Metadata path mismatches: #{dataset.path_mismatches.length}
  Source revision:         #{dataset.source_revision || '(not recorded)'}
  Fingerprint:             #{dataset.input_sha256}
  Corpus writes:           0
  Report directory:        #{output}
REPORT

dataset.editions.each do |edition|
  puts "  - #{edition.fetch('edition_label')}: #{edition.fetch('entry_count')} entries, #{edition.fetch('section_count')} sections, document #{edition.fetch('document_id')}"
end

unless options[:apply]
  puts
  puts "DRY-RUN READY"
  puts "No database rows were written. Rerun with --apply --replace after reviewing the report."
  exit 0
end

result = Importers::QieyunReconstructionImporter.import!(
  dataset: dataset,
  replace: options[:replace],
  verbose: true,
  log_every: options[:log_every]
)

output.join("import_result.json").write(JSON.pretty_generate(result) + "\n", encoding: "UTF-8")
puts
puts "QIEYUN DICTIONARY IMPORT COMPLETE"
puts "Catalogue URL: /dictionary/catalogue/#{dataset.work_id}"
puts "Result: #{result.inspect}"
