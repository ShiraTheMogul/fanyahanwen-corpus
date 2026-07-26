# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require Rails.root.join("script/promote_readable_dictionary_jsonl").to_s

class PromoteReadableDictionaryJsonlTest < ActiveSupport::TestCase
  test "preserves historical forms and publishes a missing head as a visible square" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      cycle = root.join("cycle")
      import_plan = cycle.join("jiyun_only/import_plan")
      import_plan.mkpath
      config = root.join("policy.yml")
      output = root.join("publication")

      config.write(<<~YAML, encoding: "UTF-8")
        version: 1
        works:
          集韻:
            profile: jiyun_only
            mode: publish
            source_files:
              - entries.candidate_review.jsonl
              - entries.localized_source_gaps.jsonl
            minimum_entries: 2
            maximum_entries: 2
            missing_headword_placeholder: "□"
            publication_scope: test
      YAML

      write_jsonl(import_plan.join("entries.candidate_review.jsonl"), [
        entry(
          sequence: 1,
          headword: "玄",
          headwords: ["玄", "𤣥"],
          payload: "古文𤣥亦作玄",
          status: "candidate_parser_review"
        )
      ])
      write_jsonl(import_plan.join("entries.localized_source_gaps.jsonl"), [
        entry(
          sequence: 2,
          headword: nil,
          headwords: [],
          payload: "乙肱切下深貌文一",
          status: "localized_source_gap",
          review: true,
          source_gap: true
        )
      ])

      summary = DictionaryPublication::Promoter.new(
        cycle_root: cycle,
        title: "集韻",
        output_root: output,
        config_path: config
      ).run

      assert_equal 2, summary.fetch("entries")
      rows = read_jsonl(output.join("entries.ready_for_import_review.jsonl"))

      assert_equal "玄", rows[0].fetch("headword")
      assert_equal ["玄", "𤣥"], rows[0].fetch("headwords")
      assert_equal "古文𤣥亦作玄", rows[0].fetch("payload_raw")
      refute rows[0].fetch("validation_notes").any? { |note| note.include?("normal") }

      assert_equal "□", rows[1].fetch("headword")
      assert_equal ["□"], rows[1].fetch("headwords")
      assert_equal false, rows[1].fetch("parser_review_required")
      assert_equal false, rows[1].fetch("contains_source_gap")
      assert_includes rows[1].fetch("source_structure_notes"), "original_contains_source_gap=true"
      assert_includes rows[1].fetch("source_structure_notes"), "source_omits_or_does_not_encode_headword=true"
    end
  end

  test "records complex unlinked forms instead of normalising them" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      cycle = root.join("cycle")
      import_plan = cycle.join("yupian_only/import_plan")
      import_plan.mkpath
      config = root.join("policy.yml")
      output = root.join("publication")

      config.write(<<~YAML, encoding: "UTF-8")
        version: 1
        works:
          玉篇:
            profile: yupian_only
            mode: publish
            source_files: [entries.quarantined.jsonl]
            minimum_entries: 1
            maximum_entries: 1
            missing_headword_placeholder: "□"
            publication_scope: partial
      YAML

      write_jsonl(import_plan.join("entries.quarantined.jsonl"), [
        entry(
          title: "玉篇",
          sequence: 1,
          headword: "古文形",
          headwords: ["古文形", "𠀀"],
          payload: "古文形𠀀",
          status: "parser_or_source_review"
        )
      ])

      DictionaryPublication::Promoter.new(
        cycle_root: cycle,
        title: "玉篇",
        output_root: output,
        config_path: config
      ).run

      row = read_jsonl(output.join("entries.ready_for_import_review.jsonl")).first
      assert_equal "𠀀", row.fetch("headword")
      assert_equal ["𠀀"], row.fetch("headwords")
      assert_equal "古文形𠀀", row.fetch("payload_raw")
      assert row.fetch("validation_notes").any? { |note| note.start_with?("unlinked_headword_forms=") }
      assert row.fetch("validation_notes").any? { |note| note.start_with?("original_primary_headword=") }
    end
  end

  test "does not promote a review-only work" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      config = root.join("policy.yml")
      config.write(<<~YAML, encoding: "UTF-8")
        version: 1
        works:
          重修廣韻:
            profile: chongxiu_guangyun_only
            mode: review
            source_files: []
            minimum_entries: 1
            maximum_entries: 2
            missing_headword_placeholder: "□"
            publication_scope: review
      YAML

      error = assert_raises(DictionaryPublication::Error) do
        DictionaryPublication::Promoter.new(
          cycle_root: root.join("cycle"),
          title: "重修廣韻",
          config_path: config
        ).run
      end
      assert_includes error.message, "review-only"
    end
  end

  private

  def entry(title: "集韻", sequence:, headword:, headwords:, payload:, status:, review: false, source_gap: false)
    {
      "schema_version" => 3,
      "parser" => "test_parser",
      "parser_version" => "test-v1",
      "dictionary_title" => title,
      "dictionary_work_id" => 100,
      "category" => "韻書之屬",
      "document_id" => 200,
      "source_file" => "卷一.txt",
      "source_path" => "四庫全書/clean/集韻/卷一.txt",
      "source_line_start" => sequence,
      "source_line_end" => sequence,
      "sequence_number" => sequence,
      "section_sequence" => 1,
      "tone" => "平聲",
      "tone_section" => "平聲",
      "rhyme_number" => 1,
      "rhyme_label" => "東",
      "initial" => nil,
      "small_rime_number" => sequence,
      "group_sequence" => sequence,
      "is_group_head" => true,
      "headwords" => headwords,
      "headword" => headword,
      "fanqie" => nil,
      "pronunciation_marker_raw" => "",
      "pronunciation_marker_type" => nil,
      "definition" => payload,
      "payload_parts" => [payload],
      "payload_raw" => payload,
      "contains_unresolved_glyph" => payload.include?("□"),
      "contains_source_gap" => source_gap,
      "parser_review_required" => review,
      "parser_review_reasons" => review ? ["fixture_review"] : [],
      "source_structure_notes" => [],
      "dry_run_status" => status,
      "validation_notes" => []
    }
  end

  def write_jsonl(path, rows)
    path.dirname.mkpath
    File.open(path, "w:UTF-8") { |io| rows.each { |row| io.puts(JSON.generate(row)) } }
  end

  def read_jsonl(path)
    File.readlines(path, encoding: "UTF-8").reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }
  end
end
