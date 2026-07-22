#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"

options = { expected: 25_178 }
OptionParser.new do |o|
  o.on("--input FILE") { |v| options[:input] = v }
  o.on("--output FILE") { |v| options[:output] = v }
  o.on("--expected N", Integer) { |v| options[:expected] = v }
end.parse!
abort "--input and --output are required" unless options[:input] && options[:output]

rows = File.foreach(options[:input], encoding: "UTF-8").reject { |l| l.strip.empty? }.map { |l| JSON.parse(l) }
errors = []
errors << "expected #{options[:expected]} rows; found #{rows.length}" unless rows.length == options[:expected]
errors << "not all rows are 廣韻" unless rows.all? { |r| r["dictionary_title"] == "廣韻" && r["dictionary_work_id"].to_i == 127386 }
errors << "review-required rows present" if rows.any? { |r| r["parser_review_required"] }
errors << "source-gap rows present" if rows.any? { |r| r["contains_source_gap"] }
errors << "non-contiguous sequence numbers" unless rows.map { |r| r["sequence_number"].to_i } == (1..rows.length).to_a
abort errors.join("\n") if errors.any?

out = Pathname.new(options[:output])
FileUtils.mkdir_p(out.dirname)
File.open(out, "w", encoding: "UTF-8") do |io|
  rows.each do |row|
    row["dry_run_status"] = "ready_for_import_review"
    row["validation_notes"] = Array(row["validation_notes"]).reject { |note| note == "reference_control_only_already_imported" }
    row["source_structure_notes"] = (Array(row["source_structure_notes"]) + ["promoted_from_reference_control_for_unified_catalogue"]).uniq
    io.puts JSON.generate(row)
  end
end
puts "[guangyun-promote] rows=#{rows.length} output=#{out} sha256=#{Digest::SHA256.file(out).hexdigest} database_writes=0"
