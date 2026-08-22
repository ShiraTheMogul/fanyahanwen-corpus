# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

class CbdbAutoAnnotatorTest < ActiveSupport::TestCase
  test "East Asian ruler names feed automatic person annotation" do
    Dir.mktmpdir do |directory|
      cache_store = CorpusSearch::CacheStore.new(root: Pathname(directory).join("cache"))
      snapshot = {
        "version" => EastAsianAuthorityUpdater::VERSION,
        "generated_at_utc" => Time.now.utc.iso8601,
        "rulers" => [{
          "qid" => "QTEST1", "source" => "wikidata_east_asia", "country" => "Japan",
          "label" => "孝徳天皇", "local_label" => "孝徳天皇", "han_names" => ["孝徳天皇", "孝德天皇"],
          "readings" => ["Emperor Kōtoku"], "reign_start_year" => 645, "reign_end_year" => 654,
          "positions" => ["Emperor of Japan"], "source_url" => "https://www.wikidata.org/wiki/QTEST1",
          "provenance" => ["Wikidata CC0", "Wikipedia era list (CC BY-SA 4.0)"]
        }],
        "eras" => []
      }
      cache_store.write_json(EastAsianAuthorityUpdater::SNAPSHOT_PATH, snapshot)
      historical = HistoricalAuthorityIndex.build_if_needed!(cache_store: cache_store, snapshot: snapshot, logger: nil)
      store = HistoricalAuthorityStore.new(
        cbdb_path: nil, cbdb_release: {}, lookup_path: nil,
        historical_path: historical.path, cache_store: cache_store, logger: nil
      )

      result = CbdbAutoAnnotator.call(
        text: "孝德天皇詔曰",
        metadata: { "corpus_root" => "日本漢文", "year_start" => 647, "year_end" => 647 },
        store: store
      )
      item = result.items.find { |row| row.fetch("text") == "孝德天皇" }
      assert item
      assert_equal "person", item.fetch("kind")
      assert_equal "high", item.fetch("confidence")
      assert_equal "QTEST1", item.fetch("candidates").first.fetch("id")
    end
  end

  test "one-character Shang diviners require divination syntax when the workbook is installed" do
    skip "viewer/data/shang_people.xlsx is not installed" unless HistoricalAuthorityIndex::SUPPLEMENTARY_SOURCE_PATH.file?

    Dir.mktmpdir do |directory|
      cache_store = CorpusSearch::CacheStore.new(root: Pathname(directory).join("cache"))
      snapshot = { "version" => EastAsianAuthorityUpdater::VERSION, "generated_at_utc" => Time.now.utc.iso8601, "rulers" => [], "eras" => [] }
      cache_store.write_json(EastAsianAuthorityUpdater::SNAPSHOT_PATH, snapshot)
      historical = HistoricalAuthorityIndex.build_if_needed!(cache_store: cache_store, snapshot: snapshot, logger: nil)
      store = HistoricalAuthorityStore.new(
        cbdb_path: nil, cbdb_release: {}, lookup_path: nil,
        historical_path: historical.path, cache_store: cache_store, logger: nil
      )

      positive = CbdbAutoAnnotator.call(text: "丁未卜，韋，貞：吉。", metadata: { "period" => "商朝" }, store: store)
      assert positive.items.any? { |item| item.fetch("text") == "韋" }

      broken = CbdbAutoAnnotator.call(text: "卜。韋貞", metadata: { "period" => "商朝" }, store: store)
      refute broken.items.any? { |item| item.fetch("text") == "韋" }

      later = CbdbAutoAnnotator.call(text: "丁未卜韋貞", metadata: { "period" => "周朝", "year_start" => -900, "year_end" => -900 }, store: store)
      refute later.items.any? { |item| item.fetch("text") == "韋" }
    end
  end
end
