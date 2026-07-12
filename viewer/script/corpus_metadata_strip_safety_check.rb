#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "optparse"
require "pathname"

options = {
  corpus_root: nil,
  strip_report: nil,
  min_chars: 2,
  sample: 100
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby script/corpus_metadata_strip_safety_check.rb --corpus-root ../corpus --strip-report tmp/.../stripped_txt_headers.csv"
  opts.on("--corpus-root DIR", "Corpus root") { |value| options[:corpus_root] = value }
  opts.on("--strip-report CSV", "stripped_txt_headers.csv or would_strip_txt_headers.csv") { |value| options[:strip_report] = value }
  opts.on("--min-chars N", Integer, "Warn for stripped files with fewer than N non-whitespace chars. Default: 2") { |value| options[:min_chars] = value }
  opts.on("--sample N", Integer, "Rows to print per bucket. Default: 100") { |value| options[:sample] = value }
end.parse!

abort "missing --corpus-root" unless options[:corpus_root]
abort "missing --strip-report" unless options[:strip_report]

corpus_root = Pathname(options.fetch(:corpus_root)).expand_path
strip_report = Pathname(options.fetch(:strip_report)).expand_path
abort "corpus root does not exist: #{corpus_root}" unless corpus_root.directory?
abort "strip report does not exist: #{strip_report}" unless strip_report.file?

counts = Hash.new(0)
problems = []
small = []
checked = 0

CSV.foreach(strip_report, headers: true, encoding: "bom|utf-8") do |row|
  status = row["status"].to_s
  counts[status] += 1
  next unless status == "stripped" || status == "would_strip"

  rel = row["path"].to_s
  path = corpus_root.join(rel)
  checked += 1

  unless path.file?
    problems << ["missing", rel, ""]
    next
  end

  text = path.read(encoding: "UTF-8", invalid: :replace, undef: :replace, replace: "�")
  body = text.strip
  if body.empty?
    problems << ["empty", rel, ""]
  elsif body.length < options.fetch(:min_chars)
    small << ["tiny", rel, body.inspect]
  end
end

puts "strip_report=#{strip_report}"
puts "checked_stripped_or_would_strip=#{checked}"
counts.sort.each { |key, value| puts "status #{key}=#{value}" }
puts "empty_or_missing=#{problems.length}"
puts "tiny_under_#{options.fetch(:min_chars)}=#{small.length}"

unless problems.empty?
  puts "\nEMPTY/MISSING SAMPLE"
  problems.first(options.fetch(:sample)).each { |row| puts row.join("\t") }
end

unless small.empty?
  puts "\nTINY SAMPLE"
  small.first(options.fetch(:sample)).each { |row| puts row.join("\t") }
end

exit(problems.empty? ? 0 : 2)
