require_relative "../../test_helper"
require "fileutils"
require "tmpdir"

class CorpusSearchPreparedSearchTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname.new(Dir.mktmpdir("prepared-search"))
    @cache_store = CorpusSearch::CacheStore.new(root: @directory)
    @query = CorpusSearch::Query.from_params(
      "mode" => "exact",
      "q" => "仁",
      "punctuation" => "ignore",
      "characters" => "common",
      "roles" => ["canonical"]
    )
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
  end

  test "writes a frozen record once and refuses later completion changes" do
    prepared = CorpusSearch::PreparedSearch.create!(query: @query, cache_store: @cache_store)
    snapshot = { "snapshot_id" => "snapshot-1" }
    artifacts = [{ "path" => "results.csv", "bytes" => 10, "sha256" => "abc" }]

    assert prepared.complete!(
      progress: { "hits_found" => 2 },
      outputs: { "zip_path" => "/tmp/result.zip" },
      corpus_snapshot: snapshot,
      artifact_manifest: artifacts
    )
    assert prepared.frozen?
    assert_equal "snapshot-1", prepared.frozen_record.dig("corpus_snapshot", "snapshot_id")

    assert_not prepared.complete!(
      progress: { "hits_found" => 999 },
      outputs: { "zip_path" => "/tmp/changed.zip" },
      corpus_snapshot: { "snapshot_id" => "changed" },
      artifact_manifest: []
    )

    prepared.load!
    assert_equal 2, prepared.payload.dig("progress", "hits_found")
    assert_equal "/tmp/result.zip", prepared.payload.dig("outputs", "zip_path")
    assert_equal "snapshot-1", prepared.frozen_record.dig("corpus_snapshot", "snapshot_id")
  end

  test "stores comparison and source record identifiers" do
    source = CorpusSearch::PreparedSearch.create!(query: @query, cache_store: @cache_store)
    comparison = CorpusSearch::ComparisonDefinition.new(
      dimension: "nation",
      left_group: "日本",
      right_group: "越南"
    )

    prepared = CorpusSearch::PreparedSearch.create!(
      query: @query,
      comparison: comparison,
      source_prepared: source,
      cache_store: @cache_store
    )

    assert_equal source.id, prepared.source_prepared_id
    assert_equal comparison.to_h, prepared.comparison.to_h
  end
end
