#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "../lib/dictionary_import/ready_jsonl"

options = {
  output: "tmp/dictionary_import/database_import_plan",
  expected_entries: nil,
  edition_label: nil,
  source_label: "Fanya Hanwen Corpus"
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby script/plan_dictionary_database_import.rb --entries FILE --corpus-root DIR [options]"
  opts.on("--entries FILE", "Reviewed ready-for-import JSONL") { |value| options[:entries] = value }
  opts.on("--corpus-root DIR", "Corpus root containing 四庫全書, 中國漢文, etc.") { |value| options[:corpus_root] = value }
  opts.on("--output DIR", "Plan output directory") { |value| options[:output] = value }
  opts.on("--expected-entries N", Integer, "Required exact entry count") { |value| options[:expected_entries] = value }
  opts.on("--edition-label LABEL", "Edition label stored for the dictionary work") { |value| options[:edition_label] = value }
  opts.on("--source-label LABEL", "Human-readable corpus source label") { |value| options[:source_label] = value }
  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit 0
  end
end

parser.parse!

missing = %i[entries corpus_root].reject { |key| options[key] && !options[key].to_s.empty? }
unless missing.empty?
  warn "Missing required options: #{missing.map { |key| "--#{key.to_s.tr('_', '-')}" }.join(', ')}"
  warn parser
  exit 2
end

dataset = DictionaryImport::ReadyJsonl.new(
  entries_path: options[:entries],
  corpus_root: options[:corpus_root],
  expected_entries: options[:expected_entries]
).load!

output = dataset.write_plan(
  output_dir: options[:output],
  edition_label: options[:edition_label],
  source_label: options[:source_label]
)

summary = dataset.summary
puts "[dictionary-plan] dictionary=#{summary['dictionary_title'].inspect} work_id=#{summary['corpus_work_id'].inspect}"
puts "[dictionary-plan] entries=#{summary['entries']} sections=#{summary['sections']} groups=#{summary['groups']} readings=#{summary['readings']}"
puts "[dictionary-plan] documents=#{summary['documents']} blockers=#{summary['blockers']} warnings=#{summary['warnings']}"
puts "[dictionary-plan] output=#{output}"

exit(dataset.valid? ? 0 : 1)
