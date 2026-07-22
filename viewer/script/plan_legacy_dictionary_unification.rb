#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../config/environment"
require "csv"
require "fileutils"
require "json"
require "optparse"
require Rails.root.join("resources/importers/legacy_structured_dictionary_catalogue_importer").to_s

options = {
  kangxi: Rails.root.join("resources/kangxi/kx_full.xlsx").to_s,
  shuowen: Rails.root.join("resources/fanyahanwen_research/shuowen.xlsx").to_s,
  output: Rails.root.join("tmp/dictionary_import/legacy_unification_plan").to_s
}
OptionParser.new do |o|
  o.on("--kangxi FILE") { |v| options[:kangxi] = v }
  o.on("--shuowen FILE") { |v| options[:shuowen] = v }
  o.on("--output DIR") { |v| options[:output] = v }
end.parse!

plan = Importers::LegacyStructuredDictionaryCatalogueImporter.plan(kangxi_xlsx: options[:kangxi], shuowen_xlsx: options[:shuowen])
out = Pathname.new(options[:output]).expand_path
FileUtils.rm_rf(out)
FileUtils.mkdir_p(out)
blockers = []
summary = {}
plan.each do |kind, data|
  blockers.concat(data.fetch("blockers").map { |b| [kind, b] })
  summary[kind] = {
    title: data["title"], corpus_work_id: data["corpus_work_id"], sections: data["sections"].length,
    entries: data["entries"].length, references: data["entries"].sum { |e| e["source_rows"].length },
    linked_characters: data["entries"].count { |e| e["linked_glyph"].present? }, fingerprint: data["fingerprint"], blockers: data["blockers"].length
  }
end
CSV.open(out.join("blockers.csv"), "w", write_headers: true, headers: %w[dictionary blocker]) { |csv| blockers.each { |r| csv << r } }
File.write(out.join("summary.json"), JSON.pretty_generate(summary.merge(passed: blockers.empty?, database_writes: 0)) + "\n")
File.write(out.join("summary.txt"), summary.map { |k,v| "#{k}: sections=#{v[:sections]} entries=#{v[:entries]} references=#{v[:references]} linked_characters=#{v[:linked_characters]} blockers=#{v[:blockers]}" }.join("\n") + "\npassed=#{blockers.empty?}\ndatabase_writes=0\n")
puts File.read(out.join("summary.txt"))
exit(blockers.empty? ? 0 : 1)
