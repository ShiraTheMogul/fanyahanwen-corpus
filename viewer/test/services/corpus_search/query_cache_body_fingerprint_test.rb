require_relative "../../test_helper"
require "fileutils"
require "tmpdir"

class CorpusSearchQueryCacheBodyFingerprintTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname.new(Dir.mktmpdir("query-cache-fingerprint"))
    @cache_store = CorpusSearch::CacheStore.new(root: @directory)
    @query = CorpusSearch::Query.from_params(
      "mode" => "exact",
      "q" => "仁",
      "roles" => ["canonical"]
    )
    @document = {
      "id" => "doc-1",
      "path" => "中國漢文/clean/text.txt",
      "fingerprint" => "10:1.0"
    }
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
  end

  test "stores the body fingerprint beside hits and searchable size" do
    cache = CorpusSearch::QueryCache.new(query: @query, cache_store: @cache_store)
    cache.write_hits_for(
      @document,
      [{ "start_offset" => 0, "end_offset" => 1 }],
      searchable_characters: 12,
      body_fingerprint: "a" * 64
    )
    cache.save!

    reloaded = CorpusSearch::QueryCache.new(query: @query, cache_store: @cache_store)
    assert_equal 12, reloaded.current_searchable_characters_for(@document)
    assert_equal "a" * 64, reloaded.current_body_fingerprint_for(@document)
  end
  test "stores denominator data even when an index proves zero hits" do
    cache = CorpusSearch::QueryCache.new(query: @query, cache_store: @cache_store)
    cache.write_document_stats_for(
      @document,
      searchable_characters: 24,
      body_fingerprint: "b" * 64,
      hits: []
    )
    cache.save!

    reloaded = CorpusSearch::QueryCache.new(query: @query, cache_store: @cache_store)
    assert_equal [], reloaded.current_hits_for(@document)
    assert_equal 24, reloaded.current_searchable_characters_for(@document)
    assert_equal "b" * 64, reloaded.current_body_fingerprint_for(@document)
  end

end
