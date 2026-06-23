# app/services/importers/refresh_variant_mappings_from_moe.rb
#
# Usage:
#   VERBOSE=1 rails runner app/services/importers/refresh_variant_mappings_from_moe.rb resources/moe_variants_1141231.csv
#
# Behavior:
# - Deletes ALL existing VariantMapping rows (old data is removed)
# - Imports Unicode mappings only
# - Skips blank glyph rows
# - Works with either:
#   A) Enriched CSV headers: glyph + canonical_glyph
#   B) Raw MOE headers: 字形 + 字號 + 字級 + 對應正字號 (derives canonical glyphs)

require "csv"
require "set"

csv_path = ARGV[0]
abort "ERROR: Provide a CSV path" if csv_path.nil? || csv_path.strip.empty?
abort "ERROR: File not found: #{csv_path}" unless File.exist?(csv_path)

verbose = ENV["VERBOSE"] == "1" || ENV["VERBOSE"] == "true"

BATCH_SIZE = 5000

def blank?(s)
  s.nil? || s.strip.empty?
end

# Return first non-blank value from the row for the given keys
def pick(row, *keys)
  keys.each do |k|
    v = row[k]
    return v unless v.nil?
  end
  nil
end

puts "[MOE refresh] Loading CSV: #{csv_path}" if verbose

# Read once into memory (92k rows is fine) so we can do 2-pass derivation when needed.
# encoding: "bom|utf-8" handles Excel/UTF-8 BOM cleanly.
table = CSV.read(csv_path, headers: true, encoding: "bom|utf-8")
headers = table.headers.compact.map(&:to_s)

puts "[MOE refresh] Headers: #{headers.join(', ')}" if verbose

has_canonical_glyph = headers.include?("canonical_glyph")

# If there's no canonical_glyph column, we need to derive base glyphs from raw MOE columns.
# canonical_by_id: maps "正字號" -> "glyph"
canonical_by_id = {}

unless has_canonical_glyph
  # Build canonical map from rows where 字級 == 正字
  table.each do |r|
    grade = pick(r, "字級", "grade")&.to_s&.strip
    next unless grade == "正字"

    moe_id = pick(r, "字號", "moe_id")&.to_s&.strip
    glyph  = pick(r, "字形", "glyph")&.to_s&.strip

    next if blank?(moe_id) || blank?(glyph)

    # Use only first character if anything weird slips in
    canonical_by_id[moe_id] = glyph[0]
  end

  puts "[MOE refresh] Derived canonical count=#{canonical_by_id.size}" if verbose
end

# Hard reset: remove old bad data either way
VariantMapping.delete_all

written = 0
skipped_blank = 0
skipped_self = 0
skipped_dup = 0

seen_variant_cp = Set.new
batch = []

def flush_batch!(batch)
  return if batch.empty?
  VariantMapping.insert_all!(batch)
  batch.clear
end

table.each_with_index do |r, i|
  variant = pick(r, "glyph", "字形")&.to_s&.strip
  if blank?(variant)
    skipped_blank += 1
    next
  end
  variant = variant[0]

  base =
    if has_canonical_glyph
      cg = pick(r, "canonical_glyph")&.to_s&.strip
      blank?(cg) ? nil : cg[0]
    else
      canon_id = pick(r, "對應正字號", "canonical_moe_id")&.to_s&.strip
      blank?(canon_id) ? nil : canonical_by_id[canon_id]
    end

  if base.nil?
    skipped_blank += 1
    next
  end

  if variant == base
    skipped_self += 1
    next
  end

  variant_cp = variant.ord
  if seen_variant_cp.include?(variant_cp)
    skipped_dup += 1
    next
  end
  seen_variant_cp.add(variant_cp)

  batch << {
    variant_codepoint: variant_cp,
    base_codepoint: base.ord,
    source: "moe_taiwan_moe",
    created_at: Time.current,
    updated_at: Time.current
  }

  if batch.length >= BATCH_SIZE
    flush_batch!(batch)
    written += BATCH_SIZE
    puts "[MOE refresh] progress rows=#{i + 1} written~=#{written} skipped_blank=#{skipped_blank} skipped_self=#{skipped_self} skipped_dup=#{skipped_dup}" if verbose
  end
end

# Flush remaining
written += batch.length
flush_batch!(batch)

puts "[MOE refresh] Complete."
puts "[MOE refresh] written=#{written} skipped_blank=#{skipped_blank} skipped_self=#{skipped_self} skipped_dup=#{skipped_dup}"
puts "Done. VariantMapping.count=#{VariantMapping.count}"
