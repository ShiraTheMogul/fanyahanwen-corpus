require_relative "../../test_helper"

class CorpusSearchExportWriterAdvancedContextTest < ActiveSupport::TestCase
  Prepared = Struct.new(:query)

  test "keeps only short body contexts in the compact R occurrence table" do
    query = CorpusSearch::Query.from_params(
      "mode" => "exact",
      "q" => "仁",
      "roles" => ["canonical"]
    )
    writer = CorpusSearch::ExportWriter.new(prepared_search: Prepared.new(query))
    hit = {
      "doc_id" => "doc-1",
      "document_id" => "doc-1",
      "work_id" => "work-1",
      "occurrence_key" => "doc-1:10:11:10:11",
      "source_url" => "/corpus_viewer/text?start=10&end=11",
      "path" => "中國漢文/clean/text.txt",
      "search_start_offset" => 10,
      "search_end_offset" => 11,
      "matched_text" => "仁",
      "left_context" => ("甲" * 30) + "，乙",
      "right_context" => "丙。" + ("丁" * 30)
    }

    row = writer.send(:analysis_occurrence_row, hit, occurrence_id: 1)

    assert_equal "甲甲甲甲乙", row.fetch("left_neighbours")
    assert_equal "丙丁丁丁丁", row.fetch("right_neighbours")
    assert_equal "仁⇒仁", row.fetch("matched_forms")
    assert_equal "doc-1:10:11:10:11", row.fetch("occurrence_key")
    assert_equal "/corpus_viewer/text?start=10&end=11", row.fetch("source_url")
    assert_equal 5, row.fetch("left_neighbours").each_char.count
    assert_equal 5, row.fetch("right_neighbours").each_char.count
  end
  test "records entered terms beside the exact source forms in proximity hits" do
    query = CorpusSearch::Query.from_params(
      "mode" => "proximity",
      "terms" => ["仁", "義"],
      "roles" => ["canonical"]
    )
    writer = CorpusSearch::ExportWriter.new(prepared_search: Prepared.new(query))
    hit = {
      "doc_id" => "doc-1",
      "path" => "中國漢文/clean/text.txt",
      "start_offset" => 5,
      "end_offset" => 8,
      "search_start_offset" => 5,
      "search_end_offset" => 8,
      "matched_text" => "仁與義",
      "left_context" => "",
      "right_context" => "",
      "term_matches" => [
        { "term" => "仁", "start_offset" => 5, "end_offset" => 6 },
        { "term" => "義", "start_offset" => 7, "end_offset" => 8 }
      ]
    }

    row = writer.send(:analysis_occurrence_row, hit, occurrence_id: 1)

    assert_equal "仁⇒仁 | 義⇒義", row.fetch("matched_forms")
  end

end
