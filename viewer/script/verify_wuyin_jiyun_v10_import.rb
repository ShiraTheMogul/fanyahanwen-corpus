#!/usr/bin/env ruby
# frozen_string_literal: true

# Run through Rails:
#   bin/rails runner script/verify_wuyin_jiyun_v10_import.rb
#
# This verifies the corrected normalized import. It does not write anything.
work = DictionaryWork.find_by!(corpus_work_id: 127372)
expected_tones = { "平聲" => 44, "上聲" => 43, "去聲" => 47, "入聲" => 26 }
actual_tones = work.dictionary_sections.group(:tone).count

checks = {
  title: work.title == "五音集韻",
  entries: work.dictionary_entries.count == 46_977,
  stored_entries: work.entry_count == 46_977,
  sections: work.dictionary_sections.count == 160,
  stored_sections: work.section_count == 160,
  groups: work.group_count == 3_855,
  readings: work.reading_count == 3_748,
  tones: expected_tones.all? { |tone, count| actual_tones[tone].to_i == count },
  no_unassigned_tone: work.dictionary_sections.where(tone: [nil, ""]).none?
}

inheritable_entries = work.dictionary_entries
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

puts "[wuyin-v10] title=#{work.title.inspect} corpus_work_id=#{work.corpus_work_id}"
puts "[wuyin-v10] entries=#{work.dictionary_entries.count} expected=46977"
puts "[wuyin-v10] sections=#{work.dictionary_sections.count} expected=160"
puts "[wuyin-v10] groups=#{work.group_count} expected=3855"
puts "[wuyin-v10] readings=#{work.reading_count} expected=3748"
puts "[wuyin-v10] tones=#{actual_tones.inspect} expected=#{expected_tones.inspect}"
puts "[wuyin-v10] entries_with_inheritable_group_reading=#{inheritable_entries}"
puts "[wuyin-v10] passed=#{checks.values.all?}"

abort "五音集韻 v10 verification failed: #{checks.reject { |_name, passed| passed }.keys.join(', ')}" unless checks.values.all?
