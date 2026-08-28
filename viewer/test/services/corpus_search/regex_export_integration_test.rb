require_relative "../../test_helper"
require "csv"
require "fileutils"
require "json"
require "tmpdir"

class CorpusSearchRegexExportIntegrationTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname.new(Dir.mktmpdir("regex-export"))
    @corpus_root = @directory.join("corpus")
    @cache_store = CorpusSearch::CacheStore.new(root: @directory.join("cache"))
    path = @corpus_root.join("中國漢文/clean/周朝/text.txt")
    FileUtils.mkdir_p(path.dirname)
    path.write("# TITLE: 天地玄黃 metadata only\n\n天地，玄黃。\n")
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
  end

  test "prepared-analysis rows retain the regular expression as the matched term" do
    query = regex_query("天地玄[黃黄]")
    csv_path = @directory.join("document_counts.csv")

    Rails.configuration.x.stub(:corpus_root, @corpus_root) do
      manifest = quietly do
        CorpusSearch::Manifest.load(
          root: @corpus_root,
          cache_store: @cache_store,
          refresh: true,
          force: true
        )
      end
      writer = CorpusSearch::AnalysisDatasetWriter.new(
        query: query,
        manifest: manifest,
        cache_store: @cache_store
      )
      writer.write!(csv_path: csv_path)
    end

    row = CSV.read(csv_path, headers: true).first
    assert_equal "1", row["occurrences"]
    assert_equal ["天地玄[黃黄]"], JSON.parse(row["matched_terms_json"])
  end

  test "result and flashcard exports retain a single-expression regex query" do
    query = regex_query("天地玄[黃黄]")
    prepared = Struct.new(:query).new(query)
    writer = CorpusSearch::ExportWriter.new(prepared_search: prepared, cache_store: @cache_store)
    hit = {
      "matched_text" => "天地，玄黃",
      "snippet" => "天地，玄黃",
      "title" => "千字文",
      "author" => "周興嗣",
      "period" => "梁",
      "nation" => "中國",
      "path" => "中國漢文/clean/梁/千字文.txt",
      "equivalence_matches" => [],
      "term_matches" => []
    }

    row = writer.send(:result_row, hit, occurrence_id: 1)
    query_text_index = CorpusSearch::ExportWriter::RESULT_COLUMNS.index("query_text")
    assert_equal "天地玄[黃黄]", row.fetch(query_text_index)

    flashcard = writer.send(:flashcard_row, hit)
    assert_equal "天地玄[黃黄]", flashcard.fetch(2)
  end

  private

  def regex_query(expression)
    CorpusSearch::Query.new(
      search_definition: CorpusSearch::SearchDefinition.new(
        mode: "regex",
        query_text: expression,
        punctuation: "ignore"
      ),
      presentation_options: CorpusSearch::PresentationOptions.new,
      requested: true
    )
  end

  def quietly
    old = ENV["CORPUS_SEARCH_SILENT"]
    ENV["CORPUS_SEARCH_SILENT"] = "1"
    yield
  ensure
    ENV["CORPUS_SEARCH_SILENT"] = old
  end
end
