# frozen_string_literal: true
#
# Import 808 common CJK characters as a boolean-like property.
# Trilateral Cooperation Secretariat. (2015). 中日韩共同常用八百八汉字表 [Booklet of the 808 Commonly Used Chinese Characters in China, Japan and the ROK]. Trilateral Cooperation Secretariat.
#
# Usage:
#   bin/rails runner script/import_cjk_808_common.rb /absolute/or/relative/path/to/808中日韓通用漢字.txt
#
# Stores:
#   field:  cjk_808_common
#   value:  Yes
#   source: Trilateral Cooperation Secretariat, 2015
#
# Idempotent: safe to re-run (uses find_or_create_by!).

path = ARGV[0].to_s.strip
abort "Usage: bin/rails runner script/import_cjk_808_common.rb path/to/808中日韓通用漢字.txt" if path.empty?
abort "File not found: #{path}" unless File.exist?(path)

SOURCE = "Trilateral Cooperation Secretariat, 2015"
FIELD  = "cjk_808_common"
VALUE  = "Yes"

chars = File.read(path, encoding: "UTF-8")
  .lines
  .map(&:strip)
  .reject(&:empty?)
  .map { |line| line.each_char.first } # one character per line
  .uniq

puts "Loaded #{chars.length} unique characters from #{path}"

inserted = 0

ActiveRecord::Base.transaction do
  chars.each_with_index do |ch, i|
    cp = ch.ord

    cc = CharacterCodepoint.find_or_create_by!(codepoint: cp) do |row|
      row.chr = ch if row.respond_to?(:chr=)
    end

    prop = CharacterProperty.find_or_create_by!(
      character_codepoint_id: cc.id,
      source: SOURCE,
      field: FIELD,
      value: VALUE
    )

    inserted += 1 if prop.previously_new_record?
    puts "Processed #{i + 1} / #{chars.length}" if ((i + 1) % 200).zero?
  end
end

total = CharacterProperty.where(source: SOURCE, field: FIELD, value: VALUE).count
puts "Done. Inserted new rows this run: #{inserted}. Total in DB for #{FIELD}: #{total}"
