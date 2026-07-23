# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require Rails.root.join("lib/dictionary_import/ready_jsonl").to_s

class ReadyJsonlInitialScopeTest < ActiveSupport::TestCase
  test "allows several initials inside one rhyme section" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      work_dir = root.join("中國漢文/clean/五音集韻")
      work_dir.mkpath
      source_path = "中國漢文/clean/五音集韻/五音集韻__juan_01.txt"
      source_file = work_dir.join("五音集韻__juan_01.txt")
      source_file.write("東\n冬\n江\n缸\n", encoding: "UTF-8")

      work_dir.join("metadata.json").write(
        JSON.pretty_generate(
          "schema_version" => 1,
          "work_id" => 127372,
          "title" => "五音集韻",
          "documents" => [
            {
              "document_id" => 1,
              "file" => source_file.basename.to_s,
              "path" => source_path
            }
          ]
        ) + "\n",
        encoding: "UTF-8"
      )

      entries_path = root.join("entries.jsonl")
      rows = [
        row(1, "東", 1, "平聲", 1, "東", "見", source_path, source_file.basename.to_s),
        row(2, "冬", 1, "平聲", 1, "東", "溪", source_path, source_file.basename.to_s),
        row(3, "江", 2, "平聲", 2, "江", "見", source_path, source_file.basename.to_s),
        row(4, "缸", 2, "平聲", 2, "江", "見", source_path, source_file.basename.to_s)
      ]
      entries_path.write(rows.map { |value| JSON.generate(value) }.join("\n") + "\n", encoding: "UTF-8")

      dataset = DictionaryImport::ReadyJsonl.new(
        entries_path: entries_path,
        corpus_root: root,
        expected_entries: 4
      ).load!

      assert dataset.valid?, dataset.errors.inspect
      first, second = dataset.sections
      assert_nil first["initial"]
      assert_equal %w[見 溪], first["initials"]
      assert_equal 2, first["initial_count"]
      assert_equal "見", second["initial"]
      assert_equal ["見"], second["initials"]
      assert_equal 1, second["initial_count"]
    end
  end

  private

  def row(sequence, headword, section_sequence, tone, rhyme_number, rhyme_label, initial, source_path, source_file)
    {
      "dictionary_title" => "五音集韻",
      "dictionary_work_id" => 127372,
      "document_id" => 1,
      "source_file" => source_file,
      "source_path" => source_path,
      "source_line_start" => sequence,
      "source_line_end" => sequence,
      "sequence_number" => sequence,
      "section_sequence" => section_sequence,
      "group_sequence" => sequence,
      "tone" => tone,
      "rhyme_number" => rhyme_number,
      "rhyme_label" => rhyme_label,
      "initial" => initial,
      "headword" => headword,
      "headwords" => [headword],
      "definition" => "",
      "payload_raw" => headword,
      "parser" => "wuyin_jiyun_structural_v10",
      "parser_version" => "10",
      "dry_run_status" => "ready_for_import_review",
      "parser_review_required" => false,
      "contains_source_gap" => false,
      "is_group_head" => true,
      "pronunciation_marker_raw" => ""
    }
  end
end
