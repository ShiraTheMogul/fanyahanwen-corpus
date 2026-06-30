require_relative "../../test_helper"
require "fileutils"
require "tmpdir"

class CorpusSearchFrequencySnapshotTest < ActiveSupport::TestCase
  FakeManifest = Struct.new(:documents)

  setup do
    @directory = Pathname.new(Dir.mktmpdir("frequency-snapshot"))
    @cache_store = CorpusSearch::CacheStore.new(root: @directory)
    @manifest = FakeManifest.new([
      { "id" => "doc-1", "fingerprint" => "10:1" },
      { "id" => "doc-2", "fingerprint" => "20:2" }
    ])
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
  end

  test "builds one aggregate cache from current term indexes" do
    write_term_index("之", "doc-1" => 3, "doc-2" => 2)
    write_term_index("不", "doc-2" => 4)

    payload = CorpusSearch::FrequencySnapshot.build!(
      terms: %w[之 不],
      manifest: @manifest,
      cache_store: @cache_store
    )

    assert_equal({ "之" => 5, "不" => 4 }, payload["counts"])
    assert_equal({ "之" => 5, "不" => 4 }, CorpusSearch::FrequencySnapshot.counts(cache_store: @cache_store))
    assert_empty payload["stale_terms"]
  end

  test "does not present stale term indexes as current frequencies" do
    payload = CorpusSearch::TermIndex.fresh_payload_for(
      "之",
      manifest_fingerprint: "old-manifest",
      total_documents: 2
    )
    payload["generated_at"] = Time.now.utc.iso8601
    payload["entries"] = { "doc-1" => { "fingerprint" => "10:1", "count" => 99 } }
    @cache_store.write_json(CorpusSearch::TermIndex.cache_path_for("之"), payload)

    snapshot = CorpusSearch::FrequencySnapshot.build!(
      terms: ["之"],
      manifest: @manifest,
      cache_store: @cache_store
    )

    assert_empty snapshot["counts"]
    assert_equal ["之"], snapshot["stale_terms"]
  end

  private

  def write_term_index(term, counts)
    payload = CorpusSearch::TermIndex.fresh_payload_for(
      term,
      manifest_fingerprint: CorpusSearch::TermIndex.manifest_fingerprint(@manifest),
      total_documents: @manifest.documents.length
    )
    payload["generated_at"] = Time.now.utc.iso8601
    payload["entries"] = counts.to_h do |doc_id, count|
      document = @manifest.documents.find { |row| row["id"] == doc_id }
      [doc_id, { "fingerprint" => document.fetch("fingerprint"), "count" => count }]
    end
    @cache_store.write_json(CorpusSearch::TermIndex.cache_path_for(term), payload)
  end
end
