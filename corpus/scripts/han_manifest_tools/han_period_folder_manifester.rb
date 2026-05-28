#!/usr/bin/env ruby
# frozen_string_literal: true

# han_period_folder_manifester.rb
#
# Purpose:
#   Read a TSV manifest of polities/domains and create period-sliced folders.
#
# Example:
#   ruby han_period_folder_manifester.rb --input han_manifest.tsv --root "corpus/日本漢文/clean/New system/日本" --dry-run
#   ruby han_period_folder_manifester.rb --input han_manifest.tsv --root "corpus/日本漢文/clean/New system/日本" --apply
#
# Input TSV headers:
#   polity_id    display_name    start_year    end_year    type    notes
#
# Required columns:
#   polity_id, display_name, start_year, end_year
#
# The script treats ranges as half-open:
#   1603-1871 means start at 1603 and continue until 1871.
#   This means it overlaps 明治時代 because 明治 starts in 1868.

require "csv"
require "fileutils"
require "optparse"

PERIODS = [
  { name: "鎌倉時代", start_year: 1185, end_year: 1333 },
  { name: "室町時代", start_year: 1336, end_year: 1573 },
  { name: "安土桃山時代", start_year: 1573, end_year: 1603 },
  { name: "江戸時代", start_year: 1603, end_year: 1868 },
  { name: "明治時代", start_year: 1868, end_year: 1912 }
].freeze

options = {
  input: nil,
  root: nil,
  dry_run: true,
  category_folder: nil
}

def utf8(value)
  value.to_s.dup.force_encoding("UTF-8").encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
end

OptionParser.new do |parser|
  parser.banner = "Usage: ruby han_period_folder_manifester.rb --input HAN.tsv --root ROOT [--dry-run|--apply] [--category-folder 藩]"

  parser.on("--input PATH", "Path to TSV input file") do |value|
    options[:input] = utf8(value)
  end

  parser.on("--root PATH", "Root period folder, e.g. corpus/日本漢文/clean/New system/日本") do |value|
    options[:root] = utf8(value)
  end

  parser.on("--dry-run", "Print folders that would be created, but do not create them") do
    options[:dry_run] = true
  end

  parser.on("--apply", "Actually create folders") do
    options[:dry_run] = false
  end

  parser.on("--category-folder NAME", "Optional layer between period and polity, e.g. 藩") do |value|
    options[:category_folder] = utf8(value)
  end
end.parse!

missing = []
missing << "--input" if options[:input].nil?
missing << "--root" if options[:root].nil?

unless missing.empty?
  warn "Missing required option(s): #{missing.join(', ')}"
  warn "Run: ruby han_period_folder_manifester.rb --help"
  exit 1
end

unless File.file?(options[:input])
  warn "Input file not found: #{options[:input]}"
  exit 1
end

# Keep folder names safe without changing meaningful CJK names.
def clean_folder_name(name)
  name.to_s
      .strip
      .gsub(/[\\\/\:\*\?\"\<\>\|]/, "＿")
      .gsub(/\s+/, " ")
end

# Half-open overlap:
#   active range [start_year, end_year)
#   period range [period_start, period_end)
def overlaps_period?(active_start, active_end, period_start, period_end)
  active_start < period_end && active_end > period_start
end

created = []
skipped = []

rows = CSV.read(
  options[:input],
  col_sep: "\t",
  headers: true,
  encoding: "bom|utf-8"
)

rows.each_with_index do |row, index|
  line_number = index + 2 # header is line 1

  polity_id = utf8(row["polity_id"]).strip
  display_name = utf8(row["display_name"]).strip
  start_text = utf8(row["start_year"]).strip
  end_text = utf8(row["end_year"]).strip

  if polity_id.empty? || display_name.empty? || start_text.empty? || end_text.empty?
    skipped << "line #{line_number}: missing required value"
    next
  end

  unless start_text.match?(/\A-?\d+\z/) && end_text.match?(/\A-?\d+\z/)
    skipped << "line #{line_number}: start_year/end_year must be plain years"
    next
  end

  active_start = start_text.to_i
  active_end = end_text.to_i

  if active_end <= active_start
    skipped << "line #{line_number}: end_year must be greater than start_year"
    next
  end

  folder_name = clean_folder_name(display_name)

  matching_periods = PERIODS.select do |period|
    overlaps_period?(active_start, active_end, period[:start_year], period[:end_year])
  end

  if matching_periods.empty?
    skipped << "line #{line_number}: #{display_name} does not overlap configured periods"
    next
  end

  matching_periods.each do |period|
    parts = [options[:root], period[:name]]
    parts << options[:category_folder] if options[:category_folder]
    parts << folder_name

    path = File.join(*parts)
    created << [path, polity_id]
  end
end

created.uniq.each do |path, polity_id|
  if options[:dry_run]
    puts "WOULD CREATE\t#{path}\t# #{polity_id}"
  else
    FileUtils.mkdir_p(path)
    puts "CREATED\t#{path}\t# #{polity_id}"
  end
end

unless skipped.empty?
  warn "\nSkipped rows:"
  skipped.each { |message| warn "- #{message}" }
end

puts "\nSummary: #{created.uniq.length} folder path(s) #{options[:dry_run] ? 'planned' : 'created'}; #{skipped.length} row(s) skipped."
