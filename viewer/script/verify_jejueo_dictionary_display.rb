# frozen_string_literal: true

# Run with:
#   RAILS_ENV=production bin/rails runner script/verify_jejueo_dictionary_display.rb
#
# This checks the two separate halves of dictionary display:
# 1. Rails knows that the custom fields are Koreanic pronunciation fields.
# 2. The production database actually contains the imported rows.

EXPECTED_FIELDS = {
  "reading.koreanic.jejueo.hangul" => 14,
  "reading.koreanic.jejueo.source_romanisation" => 14,
  "reading.koreanic.jejueo.compound_hangul" => 11,
  "reading.koreanic.jejueo.compound_source_romanisation" => 11,
  "reading.koreanic.jejueo.compound_attestation" => 15
}.freeze

SAMPLE_CHARACTER = "百"
SAMPLE_EXPECTED = {
  "reading.koreanic.jejueo.hangul" => "백",
  "reading.koreanic.jejueo.source_romanisation" => "beg"
}.freeze

failures = []

PronunciationRegistry.reload!

puts "[jejueo display] registry"
EXPECTED_FIELDS.each_key do |field|
  metadata = PronunciationRegistry.field_metadata(field)
  if metadata.nil?
    failures << "Registry does not recognise #{field}"
    puts "  MISSING  #{field}"
  elsif metadata[:family] != "koreanic"
    failures << "#{field} is registered under #{metadata[:family].inspect}, not koreanic"
    puts "  WRONG    #{field} family=#{metadata[:family].inspect}"
  else
    puts "  OK       #{field}"
  end
end

puts "[jejueo display] database row counts"
EXPECTED_FIELDS.each do |field, expected_count|
  actual_count = CharacterProperty.where(field: field).count
  status = actual_count == expected_count ? "OK" : "CHECK"
  puts format("  %-7s %-62s %d (expected %d)", status, field, actual_count, expected_count)
  failures << "#{field} has #{actual_count} rows; expected #{expected_count}" unless actual_count == expected_count
end

character = CharacterCodepoint.find_by(chr: SAMPLE_CHARACTER)
if character.nil?
  failures << "CharacterCodepoint is missing for #{SAMPLE_CHARACTER}"
else
  sample_rows = character.character_properties
    .where(field: SAMPLE_EXPECTED.keys)
    .pluck(:field, :value)
    .to_h

  puts "[jejueo display] sample #{SAMPLE_CHARACTER}"
  SAMPLE_EXPECTED.each do |field, expected_value|
    actual_value = sample_rows[field]
    if actual_value == expected_value
      puts "  OK       #{field}=#{actual_value}"
    else
      failures << "#{SAMPLE_CHARACTER} #{field}=#{actual_value.inspect}; expected #{expected_value.inspect}"
      puts "  MISSING  #{field}=#{expected_value}"
    end
  end

  relevant_fields = ["kKorean", "kHangul", *EXPECTED_FIELDS.keys]
  props = character.character_properties.where(field: relevant_fields).order(:field, :source, :value).to_a
  sections = FieldLens.pronunciation_sections(props)
  koreanic = sections.find { |section| section[:key] == "koreanic" }
  jejueo = koreanic && koreanic[:varieties].find { |group| group[:key] == "jejueo" }

  if koreanic.nil?
    failures << "The rendered pronunciation structure has no Koreanic section for #{SAMPLE_CHARACTER}"
  elsif jejueo.nil?
    failures << "The rendered Koreanic structure has no Jejueo subgroup for #{SAMPLE_CHARACTER}"
  else
    puts "[jejueo display] rendered grouping"
    puts "  OK       Koreanic count=#{koreanic[:count]}"
    puts "  OK       Jejueo count=#{jejueo[:props].length}"
  end
end

if failures.any?
  warn "\n[jejueo display] FAILED"
  failures.each { |failure| warn "  - #{failure}" }
  warn "\nThe database import and the pronunciation registry are separate deployment steps."
  warn "Apply the source patch, restart the Rails application, and run this check again."
  exit 1
end

puts "\n[jejueo display] PASS"
puts "The imported rows exist and Rails will place them under Koreanic > Jejueo."
