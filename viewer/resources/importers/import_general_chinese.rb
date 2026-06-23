# frozen_string_literal: true
#
# Import "General Chinese / 通字" readings into CharacterProperty
#
# Usage:
#   bin/rails runner script/import_general_chinese.rb [path/to/tungdzih-keywords.txt]
#
# Input format (UTF-8):
#   reading<TAB>漢
# Example:
#   ba<TAB>巴
#
# This script is idempotent: re-running it won't duplicate rows because
# we use find_or_create_by! and your DB has a uniqueness index.

path =
  if ARGV[0].to_s.strip != ""
    Pathname.new(ARGV[0])
  else
    Rails.root.join("resources", "fanyahanwen_research", "tungdzih-keywords.txt")
  end

unless path.exist?
  abort "File not found: #{path}"
end

SOURCE = "Chao 1983"
FIELD  = "general_chinese"

lines = File.readlines(path, encoding: "UTF-8")
puts "Reading #{lines.size} lines from #{path}"

inserted = 0
skipped  = 0

ActiveRecord::Base.transaction do
  lines.each_with_index do |line, i|
    line = line.strip
    next if line.empty? || line.start_with?("#")

    reading, chars = line.split(/\t+/, 2)
    if reading.nil? || chars.nil?
      skipped += 1
      next
    end

    reading = reading.strip
    chars   = chars.gsub(/\s+/, "") # just in case

    chars.each_char do |ch|
      cp = ch.ord

      cc = CharacterCodepoint.find_or_create_by!(codepoint: cp) do |row|
        row.chr = ch
      end

      prop = CharacterProperty.find_or_create_by!(
        character_codepoint_id: cc.id,
        source: SOURCE,
        field: FIELD,
        value: reading
      )

      inserted += 1 if prop.previously_new_record?
    end

    puts "Processed #{i + 1} / #{lines.size}" if ((i + 1) % 500).zero?
  end
end

count = CharacterProperty.where(source: SOURCE, field: FIELD).count
puts "Done."
puts "Inserted new rows this run: #{inserted}"
puts "Malformed/ignored lines: #{skipped}"
puts "Total in DB for #{SOURCE}/#{FIELD}: #{count}"
