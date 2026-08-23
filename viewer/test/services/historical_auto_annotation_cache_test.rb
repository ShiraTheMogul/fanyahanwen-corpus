# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "tmpdir"

class HistoricalAutoAnnotationCacheTest < ActiveSupport::TestCase
  FakeStore = Struct.new(:metadata) do
    def lookup_available? = true
    def historical_available? = false
  end

  setup do
    @directory = Pathname.new(Dir.mktmpdir("authority-annotation-cache"))
    @cache_store = CorpusSearch::CacheStore.new(root: @directory.join("cache"))
    @store = FakeStore.new({ "release" => "test-authority-v1", "cbdb_available" => true })
  end

  teardown do
    FileUtils.rm_rf(@directory)
  end

  test "reuses results and exposes actual authority availability" do
    calls = 0
    fake_result = Struct.new(:items, :context, :authority).new(
      [{ "start" => 0, "end" => 2, "kind" => "person", "text" => "孔子" }],
      { "year_start" => -500 },
      { "release" => "test-authority-v1", "cbdb_available" => true }
    )

    CbdbAutoAnnotator.stub(:call, lambda { |**_arguments|
      calls += 1
      fake_result
    }) do
      first = HistoricalAutoAnnotationCache.fetch(
        text: "孔子曰",
        metadata: { "period" => "春秋" },
        cache_identity: "中國漢文/孔子曰.txt",
        store: @store,
        cache_store: @cache_store
      )
      second = HistoricalAutoAnnotationCache.fetch(
        text: "孔子曰",
        metadata: { "period" => "春秋" },
        cache_identity: "中國漢文/孔子曰.txt",
        store: @store,
        cache_store: @cache_store
      )

      assert_equal false, first.cached
      assert_equal true, second.cached
      assert_equal 1, calls
      assert_equal "孔子", second.items.first.fetch("text")
      assert_equal true, second.authority.fetch("cbdb_lookup_available")
      assert_equal false, second.authority.fetch("historical_available")
    end
  end

  test "text metadata and authority metadata are part of the cache fingerprint" do
    calls = 0
    fake_result = Struct.new(:items, :context, :authority).new([], {}, {})

    CbdbAutoAnnotator.stub(:call, lambda { |**_arguments|
      calls += 1
      fake_result
    }) do
      fetch = lambda do |text, period|
        HistoricalAutoAnnotationCache.fetch(
          text: text,
          metadata: { "period" => period },
          cache_identity: "中國漢文/測試.txt",
          store: @store,
          cache_store: @cache_store
        )
      end

      fetch.call("孔子曰", "春秋")
      fetch.call("孔子曰", "春秋")
      fetch.call("孔子云", "春秋")
      fetch.call("孔子云", "戰國")
      @store.metadata["release"] = "test-authority-v2"
      fetch.call("孔子云", "春秋")

      assert_equal 4, calls
    end
  end
end
