#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../config/environment"

corpus_work_id = Integer(ARGV.fetch(0, "127393"))

puts "[dictionary-viewer-verify] corpus_work_id=#{corpus_work_id}"

required_tables = %w[
  dictionary_works
  dictionary_sections
  dictionary_entries
  dictionary_readings
  dictionary_entry_characters
  dictionary_references
]

missing_tables = required_tables.reject { |table| ActiveRecord::Base.connection.data_source_exists?(table) }
abort "[dictionary-viewer-verify] missing tables: #{missing_tables.join(', ')}" if missing_tables.any?

work = DictionaryWork.find_by(corpus_work_id: corpus_work_id)
abort "[dictionary-viewer-verify] dictionary work not found" unless work

checks = {
  sections: [work.dictionary_sections.count, work.section_count],
  entries: [work.dictionary_entries.count, work.entry_count],
  readings: [DictionaryReading.joins(:dictionary_entry).where(dictionary_entries: { dictionary_work_id: work.id }).count, work.reading_count],
  entry_characters: [DictionaryEntryCharacter.joins(:dictionary_entry).where(dictionary_entries: { dictionary_work_id: work.id }).count, work.entry_character_count],
  references: [DictionaryReference.joins(:dictionary_entry).where(dictionary_entries: { dictionary_work_id: work.id }).count, work.reference_count]
}

checks.each do |name, (actual, expected)|
  puts "[dictionary-viewer-verify] #{name}=#{actual} expected=#{expected}"
end

failed = checks.select { |_name, (actual, expected)| actual != expected }
abort "[dictionary-viewer-verify] count mismatch: #{failed.keys.join(', ')}" if failed.any?

first_section = work.dictionary_sections.order(:sequence_number).first
abort "[dictionary-viewer-verify] no sections" unless first_section

first_page = first_section.dictionary_entries
  .includes(:dictionary_readings, :dictionary_entry_characters)
  .order(:sequence_number)
  .limit(50)
  .to_a
abort "[dictionary-viewer-verify] first section has no entries" if first_page.empty?

first_entry = work.dictionary_entries
  .includes(:dictionary_section, :dictionary_readings, :dictionary_entry_characters, :dictionary_references)
  .order(:sequence_number)
  .first
abort "[dictionary-viewer-verify] first entry has no source reference" if first_entry.dictionary_references.empty?

puts "[dictionary-viewer-verify] first_section=#{first_section.sequence_number}:#{first_section.label.inspect}"
puts "[dictionary-viewer-verify] first_page_entries=#{first_page.length}"
puts "[dictionary-viewer-verify] first_entry=#{first_entry.sequence_number}:#{first_entry.headword.inspect}"
puts "[dictionary-viewer-verify] passed=true"
