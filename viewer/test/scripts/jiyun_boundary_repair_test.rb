# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require Rails.root.join("script/dictionary_import/jiyun_boundary_repair").to_s

class JiyunBoundaryRepairTest < ActiveSupport::TestCase
  test "accepts numeral group heads and recovers a postposed group head" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      source = root.join("集韻__juan_01.txt")
      source.write(<<~TEXT, encoding: "UTF-8")
        平聲一
        一○東
        〈德紅切東方也文一〉○千
        〈倉先切文十百也文十三〉仟
        〈千人之長曰仟〉○
        〈初佳切岐笄也文十七〉叉
        〈手指相錯〉差
        〈說文貳也〉
      TEXT

      parser = DictionaryImport::Parsers::Jiyun.new(
        title: "集韻",
        work_id: 127399,
        category: "韻書之屬",
        parser_name: "jiyun_multi_head_group"
      )
      result = parser.parse([
        {
          "document_sequence" => 1,
          "document_id" => 206465,
          "file" => source.basename.to_s,
          "source_relative_path" => "四庫全書/clean/集韻/集韻__juan_01.txt",
          "prepared_path" => source.to_s,
          "line_map_path" => nil
        }
      ])

      numeral = result.entries.find { |entry| entry["headword"] == "千" }
      recovered = result.entries.find { |entry| entry["headword"] == "叉" }

      assert numeral, result.entries.map { |entry| entry["headword"] }.inspect
      assert_equal true, numeral["is_group_head"]
      assert_equal "倉先切", numeral["fanqie"]
      assert_equal false, numeral["contains_source_gap"]

      assert recovered, result.entries.map { |entry| entry["headword"] }.inspect
      assert_equal true, recovered["is_group_head"]
      assert_equal "初佳切", recovered["fanqie"]
      assert_equal false, recovered["contains_source_gap"]
      assert_includes recovered["source_structure_notes"], "postposed_group_head_reordered_for_parse"

      source_gaps = result.entries.select { |entry| entry["contains_source_gap"] }
      assert_empty source_gaps
      refute result.warnings.any? { |warning| warning["kind"] == "unparsed_group_separator_segment" }
    end
  end

  test "does not invent a head when the next tail begins another group" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      source = root.join("集韻__juan_01.txt")
      source.write(<<~TEXT, encoding: "UTF-8")
        平聲一
        一○東
        〈德紅切東方也文一〉○
        〈乙肱切下深貌文一〉○鞥
        〈一憎切馬轡也文一〉
      TEXT

      parser = DictionaryImport::Parsers::Jiyun.new(
        title: "集韻",
        work_id: 127399,
        category: "韻書之屬",
        parser_name: "jiyun_multi_head_group"
      )
      result = parser.parse([
        {
          "document_sequence" => 1,
          "document_id" => 206465,
          "file" => source.basename.to_s,
          "source_relative_path" => "四庫全書/clean/集韻/集韻__juan_01.txt",
          "prepared_path" => source.to_s,
          "line_map_path" => nil
        }
      ])

      gap = result.entries.find { |entry| entry["contains_source_gap"] }
      assert gap
      assert_nil gap["headword"]
      assert_equal "missing_after_group_separator", gap["headword_status"]
    end
  end
end
