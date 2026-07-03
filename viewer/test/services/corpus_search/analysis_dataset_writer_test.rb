require_relative "../../test_helper"
require "csv"
require "fileutils"
require "json"
require "tmpdir"

class CorpusSearchAnalysisDatasetWriterTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname.new(Dir.mktmpdir("analysis-dataset"))
    @corpus_root = @directory.join("corpus")
    @cache_store = CorpusSearch::CacheStore.new(root: @directory.join("cache"))
    path = @corpus_root.join("中國漢文/clean/周朝/text.txt")
    FileUtils.mkdir_p(path.dirname)
    path.write("# TITLE: 孝孝孝 metadata only\n# AUTHOR: 孝\n\n孝，道。\n")

    unmatched = @corpus_root.join("中國漢文/clean/周朝/unmatched.txt")
    unmatched.write("# TITLE: 孝 in metadata only\n\n仁，義。\n")
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
  end

  test "writes body-only counts and a compact document table" do
    query = CorpusSearch::Query.new(
      search_definition: CorpusSearch::SearchDefinition.new(query_text: "孝", punctuation: "ignore"),
      presentation_options: CorpusSearch::PresentationOptions.new,
      requested: true
    )
    csv_path = @directory.join("document_counts.csv")
    metadata_path = @directory.join("analysis_dataset.json")

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
      writer.write!(csv_path: csv_path, metadata_path: metadata_path)
    end

    rows = CSV.read(csv_path, headers: true).sort_by { |row| row["path"] }
    assert_equal 2, rows.length

    matching = rows.find { |row| row["path"].end_with?("text.txt") }
    assert_equal "1", matching["occurrences"]
    assert_equal "1", matching["matching_document"]
    assert_equal "2", matching["searchable_characters"] # 孝道; punctuation and metadata excluded
    assert_equal ["孝"], JSON.parse(matching["matched_terms_json"])
    assert_equal 64, matching["body_fingerprint"].length

    unmatched = rows.find { |row| row["path"].end_with?("unmatched.txt") }
    assert_equal "0", unmatched["occurrences"]
    assert_equal "0", unmatched["matching_document"]
    assert_equal "2", unmatched["searchable_characters"] # 仁義 still belongs in the denominator
    assert_equal [], JSON.parse(unmatched["matched_terms_json"])
    assert_equal 64, unmatched["body_fingerprint"].length
    assert_not_equal matching["body_fingerprint"], unmatched["body_fingerprint"]

    metadata = JSON.parse(metadata_path.read)
    assert_equal 4, metadata["version"]
    assert_equal true, metadata["body_only"]
    assert_equal 2, metadata["document_count"]
    assert_equal 4, metadata["searchable_character_count"]
  end

  private

  def quietly
    old = ENV["CORPUS_SEARCH_SILENT"]
    ENV["CORPUS_SEARCH_SILENT"] = "1"
    yield
  ensure
    ENV["CORPUS_SEARCH_SILENT"] = old
  end
end
