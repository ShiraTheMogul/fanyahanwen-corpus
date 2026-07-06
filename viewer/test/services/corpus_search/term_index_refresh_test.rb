require_relative "../../test_helper"
require "fileutils"
require "tmpdir"

class CorpusSearchTermIndexRefreshTest < ActiveSupport::TestCase
  FakeManifest = Struct.new(:documents)

  setup do
    @directory = Pathname.new(Dir.mktmpdir("term-index-refresh"))
    @corpus_root = @directory.join("corpus")
    @cache_root = @directory.join("cache")
    FileUtils.mkdir_p(@corpus_root)

    @corpus_root.join("one.txt").write("# TITLE: One\n之之不\n")
    @corpus_root.join("two.txt").write("# TITLE: Two\n不之\n")

    @manifest = FakeManifest.new([
      { "id" => "one", "path" => "one.txt", "fingerprint" => "one-v1" },
      { "id" => "two", "path" => "two.txt", "fingerprint" => "two-v1" }
    ])
    @cache_store = CorpusSearch::CacheStore.new(root: @cache_root)
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
  end

  test "refreshes several single-character indexes in one operation" do
    refreshed = Rails.configuration.x.stub(:corpus_root, @corpus_root) do
      CorpusSearch::TermIndex.refresh_single_character_terms!(
        terms: %w[之 不],
        manifest: @manifest,
        cache_store: @cache_store,
        force: true
      )
    end

    assert_equal 2, refreshed

    zhi = @cache_store.read_json(CorpusSearch::TermIndex.cache_path_for("之"))
    bu = @cache_store.read_json(CorpusSearch::TermIndex.cache_path_for("不"))

    assert_equal 2, zhi.dig("entries", "one", "count")
    assert_equal 1, zhi.dig("entries", "two", "count")
    assert_equal 1, bu.dig("entries", "one", "count")
    assert_equal 1, bu.dig("entries", "two", "count")
    assert CorpusSearch::TermIndex.current_for_manifest?(
      zhi,
      CorpusSearch::TermIndex.manifest_fingerprint(@manifest)
    )

    current_ids = CorpusSearch::TermIndex.current_doc_ids_for_terms(
      terms: %w[之 不],
      manifest: @manifest,
      cache_store: @cache_store
    )
    assert_equal %w[one two], current_ids.fetch("之").sort
    assert_equal %w[one two], current_ids.fetch("不").sort
  end

  test "reports an unavailable index without calculating a replacement" do
    assert_nil CorpusSearch::TermIndex.current_doc_ids_for_terms(
      terms: ["未"],
      manifest: @manifest,
      cache_store: @cache_store
    )
    refute @cache_store.exist?(CorpusSearch::TermIndex.cache_path_for("未"))
  end

  test "rejects a malformed current index payload" do
    payload = CorpusSearch::TermIndex.fresh_payload_for(
      "之",
      manifest_fingerprint: CorpusSearch::TermIndex.manifest_fingerprint(@manifest),
      total_documents: @manifest.documents.length
    )
    payload["entries"] = nil
    @cache_store.write_json(CorpusSearch::TermIndex.cache_path_for("之"), payload)

    assert_nil CorpusSearch::TermIndex.current_doc_ids_for_terms(
      terms: ["之"],
      manifest: @manifest,
      cache_store: @cache_store
    )
  end
end
