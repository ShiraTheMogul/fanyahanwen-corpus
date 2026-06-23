# app/services/importers/import_daily_readings_shijing.rb
#
# Usage:
#   VERBOSE=1 bin/rails runner app/services/importers/import_daily_readings_shijing.rb \
#     ../corpus/中國漢文/clean/先秦/詩經/shijing_index.csv \
#     ../corpus/中國漢文/clean/先秦/詩經

require "csv"

csv_path    = ARGV[0]
corpus_root = ARGV[1]

abort "ERROR: Provide CSV path as argv[0]" if csv_path.nil? || csv_path.strip.empty?
abort "ERROR: File not found: #{csv_path}" unless File.exist?(csv_path)

abort "ERROR: Provide corpus root as argv[1]" if corpus_root.nil? || corpus_root.strip.empty?
abort "ERROR: Corpus root not found: #{corpus_root}" unless Dir.exist?(corpus_root)

SERIES_KEY  = "shijing"
BATCH_SIZE  = 1000
verbose     = (ENV["VERBOSE"] == "1" || ENV["VERBOSE"] == "true")

def blank?(s)
  s.nil? || s.to_s.strip.empty?
end

def read_metadata_and_body_flags(path)
  meta = {}
  body_present = false

  text  = File.read(path, encoding: "utf-8", invalid: :replace, undef: :replace)
  lines = text.lines

  lines.each do |line|
    stripped = line.strip

    if stripped.start_with?("#")
      stripped = stripped.sub(/\A#\s*/, "")
      if stripped.include?(":")
        k, v = stripped.split(":", 2)
        meta[k.strip] = v.to_s.strip
      end
      next
    end

    # First real non-empty non-header line => body exists
    unless stripped.empty?
      body_present = true
      break
    end
  end

  [meta, body_present]
end

puts "[DailyReading:#{SERIES_KEY}] Loading CSV: #{csv_path}" if verbose

table = CSV.read(csv_path, headers: true, encoding: "bom|utf-8")

# Re-runnable: wipe series and re-import
DailyReading.where(series_key: SERIES_KEY).delete_all

written         = 0
missing_files   = 0
marked_no_text  = 0

batch = []

flush_batch = lambda do
  return if batch.empty?
  DailyReading.insert_all!(batch)
  batch.clear
end

	table.each_with_index do |row, i|
	mao_no = row["mao_no"]&.to_s&.strip
	mother = row["mother"]&.to_s&.strip
	subcategory =
		(row["subcategory"] || row["subgroup"] || row["sub_category"] || row["sub-category"])
		&.to_s
		&.strip
	title = row["title"]&.to_s&.strip
	# For Lu/Shang etc, subcategory may be nil/blank. That's allowed.
	next if blank?(mao_no) || blank?(mother) || blank?(title)

  # Ensure this always exists
  order_index = mao_no.to_i

filename = title.end_with?(".txt") ? title : "#{title}.txt"
parts = [corpus_root, mother, subcategory, title, filename]
parts = parts.reject { |p| blank?(p) }

full_path = File.join(*parts)

# ../corpus/.../詩經/<mother>/<subcategory>//<title>/<title>.txt
rel_parts = [mother, subcategory, title, filename].reject { |p| blank?(p) }
rel_path  = File.join(*rel_parts)

has_text = true

if !File.exist?(full_path)
  has_text = false
  missing_files += 1
  puts "[missing] #{full_path}" if verbose && missing_files <= 5
else
  text = File.read(full_path, encoding: "utf-8", invalid: :replace, undef: :replace)

  # Rule 1: 笙詩 check must use the *actual file contents*
  # If the file anywhere contains "笙詩", we treat it as no-text for Daily Poem.
  if text.include?("笙詩")
    has_text = false
    marked_no_text += 1
  end

  # Rule 2: body check — do we have any real poem lines?
  # Skip metadata lines beginning with "#", and skip blank lines.
  body_present = text.each_line.any? do |line|
    stripped = line.strip
    next false if stripped.empty?
    next false if stripped.start_with?("#")
    true
  end

  has_text = false unless body_present
end

  batch << {
    series_key:  SERIES_KEY,
    mother:      mother,
    subgroup:    subcategory,   # storing subcategory into subgroup column for now
    title:       title,
    order_index: order_index,
    path:        rel_path,
    has_text:    has_text,
    created_at:  Time.current,
    updated_at:  Time.current
  }

  written += 1

  if batch.size >= BATCH_SIZE
    flush_batch.call
    if verbose && (written % (BATCH_SIZE * 5) == 0)
      puts "[DailyReading:#{SERIES_KEY}] progress rows=#{written} missing_files=#{missing_files} marked_no_text=#{marked_no_text}"
    end
  end
end

flush_batch.call

puts "[DailyReading:#{SERIES_KEY}] DONE rows=#{written} missing_files=#{missing_files} marked_no_text=#{marked_no_text}"
