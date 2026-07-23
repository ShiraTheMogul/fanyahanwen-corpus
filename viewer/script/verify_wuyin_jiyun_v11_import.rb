#!/usr/bin/env ruby
# frozen_string_literal: true

# Run through Rails:
#   bin/rails runner script/verify_wuyin_jiyun_v11_import.rb
#
# This verifies both the corrected 五音集韻 structure and the group-level
# initial data introduced by the v11 schema correction. It performs no writes.
work = DictionaryWork.find_by!(corpus_work_id: 127372)
expected_tones = { "平聲" => 44, "上聲" => 43, "去聲" => 47, "入聲" => 26 }
actual_tones = work.dictionary_sections.group(:tone).count
entries = work.dictionary_entries

missing_initials = entries.where(initial: [nil, ""]).count
section_initial_metadata_failures = work.dictionary_sections.count do |section|
  values = Array(section.metadata["initials"]).map(&:to_s).reject(&:empty?).uniq
  count = section.metadata["initial_count"].to_i
  values.empty? || count != values.length
end

checks = {
  initial_column_present: DictionaryEntry.column_names.include?("initial"),
  title: work.title == "五音集韻",
  entries: entries.count == 46_977,
  stored_entries: work.entry_count == 46_977,
  sections: work.dictionary_sections.count == 160,
  stored_sections: work.section_count == 160,
  groups: work.group_count == 3_855,
  readings: work.reading_count == 3_748,
  tones: expected_tones.all? { |tone, count| actual_tones[tone].to_i == count },
  no_unassigned_tone: work.dictionary_sections.where(tone: [nil, ""]).none?,
  no_entry_without_initial: missing_initials.zero?,
  section_initial_metadata: section_initial_metadata_failures.zero?
}

inheritable_entries = entries
  .where(group_head: false)
  .where.not(group_sequence: nil)
  .where(<<~SQL.squish)
    EXISTS (
      SELECT 1
      FROM dictionary_entries group_heads
      INNER JOIN dictionary_readings
        ON dictionary_readings.dictionary_entry_id = group_heads.id
      WHERE group_heads.dictionary_section_id = dictionary_entries.dictionary_section_id
        AND group_heads.group_sequence = dictionary_entries.group_sequence
        AND group_heads.group_head = 1
    )
  SQL
  .count

puts "[wuyin-v11] title=#{work.title.inspect} corpus_work_id=#{work.corpus_work_id}"
puts "[wuyin-v11] entries=#{entries.count} expected=46977"
puts "[wuyin-v11] sections=#{work.dictionary_sections.count} expected=160"
puts "[wuyin-v11] groups=#{work.group_count} expected=3855"
puts "[wuyin-v11] readings=#{work.reading_count} expected=3748"
puts "[wuyin-v11] tones=#{actual_tones.inspect} expected=#{expected_tones.inspect}"
puts "[wuyin-v11] entries_without_initial=#{missing_initials} expected=0"
puts "[wuyin-v11] bad_section_initial_metadata=#{section_initial_metadata_failures} expected=0"
puts "[wuyin-v11] entries_with_inheritable_group_reading=#{inheritable_entries}"
puts "[wuyin-v11] passed=#{checks.values.all?}"

abort "五音集韻 v11 verification failed: #{checks.reject { |_name, passed| passed }.keys.join(', ')}" unless checks.values.all?
