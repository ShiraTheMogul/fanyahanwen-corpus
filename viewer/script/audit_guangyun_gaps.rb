#!/usr/bin/env ruby
# frozen_string_literal: true
require "csv"
require "json"
require "optparse"
require "pathname"
require "fileutils"

options = {}
OptionParser.new do |o|
  o.on("--entries PATH") { |v| options[:entries] = v }
  o.on("--output PATH") { |v| options[:output] = v }
end.parse!
abort "Missing --entries" unless options[:entries]
abort "Missing --output" unless options[:output]
out = Pathname(options[:output]).expand_path
FileUtils.rm_rf(out); FileUtils.mkdir_p(out)
rows = File.foreach(options[:entries], chomp: true).filter_map do |line|
  row = JSON.parse(line)
  row if row["dictionary_title"] == "廣韻"
end

categories = {
  "blank_headword" => rows.select { |r| Array(r["headwords"]).include?("□") || r["headword"] == "□" },
  "blank_inside_definition" => rows.select { |r| r["definition"].to_s.include?("□") },
  "empty_definition" => rows.select { |r| r["definition"].to_s.empty? },
  "parser_review" => rows.select { |r| r["parser_review_required"] }
}
headers = %w[kind sequence_number document_id source_path source_line_start tone rhyme_label group_sequence headword fanqie definition payload_raw]
CSV.open(out.join("guangyun_gap_inventory.csv"), "wb", write_headers: true, headers: headers, force_quotes: true) do |csv|
  categories.each do |kind, list|
    list.each do |r|
      csv << [kind, r["sequence_number"], r["document_id"], r["source_path"], r["source_line_start"], r["tone"], r["rhyme_label"], r["group_sequence"], r["headword"], r["fanqie"], r["definition"], r["payload_raw"]]
    end
  end
end
summary = categories.transform_values(&:length).merge("total_entries" => rows.length, "database_writes" => 0, "corpus_writes" => 0)
out.join("summary.json").write(JSON.pretty_generate(summary) + "\n", encoding: "UTF-8")
out.join("summary.txt").write(summary.map { |k,v| "#{k}: #{v}" }.join("\n") + "\n", encoding: "UTF-8")
puts summary.inspect
