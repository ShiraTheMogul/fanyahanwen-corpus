# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

class HistoricalAuthorityIndexTest < ActiveSupport::TestCase
  test "builds ruler and era authority names from the East Asian snapshot" do
    Dir.mktmpdir do |directory|
      cache_store = CorpusSearch::CacheStore.new(root: Pathname(directory).join("cache"))
      snapshot = synthetic_snapshot
      cache_store.write_json(EastAsianAuthorityUpdater::SNAPSHOT_PATH, snapshot)

      result = HistoricalAuthorityIndex.build_if_needed!(
        cache_store: cache_store,
        snapshot: snapshot,
        logger: nil
      )

      assert result.available?
      assert result.rebuilt?
      assert HistoricalAuthorityIndex.current?(cache_store: cache_store)

      db = SQLite3::Database.new(result.path, readonly: true)
      db.results_as_hash = true
      ruler = db.get_first_row("SELECT * FROM people WHERE entity_id = 'QTEST1'")
      assert_equal "Japan", ruler["country"]
      assert_equal 645, ruler["year_start"]

      assert_equal 1, db.get_first_value("SELECT COUNT(*) FROM names WHERE entity_id = 'QTEST1' AND name_chn = '孝徳天皇'")
      traditional = db.get_first_row("SELECT * FROM people WHERE entity_id = 'QJIMMU'")
      assert_equal "traditional_or_legendary", traditional["chronology_confidence"]
      assert_includes traditional["source_citations"], "legendary, disputed, or traditional"
      era = db.get_first_row("SELECT * FROM eras WHERE era_id = 'QERA1'")
      assert_equal 645, era["start_year"]
      assert_equal "Japan", era["origin_country"]
      era_ruler = db.get_first_row("SELECT * FROM era_rulers WHERE era_id = 'QERA1'")
      assert_equal "wikidata_east_asia", era_ruler["era_source"]
      assert_equal "wikidata_east_asia", era_ruler["ruler_source"]
      assert_equal "QTEST1", era_ruler["ruler_id"]

      gaeguk = db.get_first_row("SELECT * FROM eras WHERE era_id = 'WP-Korea-gaeguk'")
      assert_equal 1392, gaeguk["epoch_start_year"]
      assert_equal 1894, gaeguk["local_use_start_year"]

      adoption = db.get_first_row("SELECT * FROM eras WHERE era_id = 'WP-Korea-test'")
      assert_nil adoption["start_year"]
      assert_equal 1403, adoption["local_use_start_year"]
      assert_equal 1, adoption["adopted_from_foreign"]


      curated = db.get_first_row("SELECT * FROM eras WHERE era_id = 'china-daxi-dashun'")
      assert_equal "大順", curated["label"]
      assert_equal 1644, curated["epoch_start_year"]
      assert_equal 1647, curated["local_use_end_year"]

      taiping = db.get_first_row("SELECT * FROM eras WHERE era_id = 'china-taiping-tianguo-main'")
      assert_equal 1851, taiping["epoch_start_year"]
      assert_equal 1864, taiping["local_use_end_year"]
      assert_equal 1, db.get_first_value(
        "SELECT COUNT(*) FROM era_names WHERE era_id = 'china-taiping-tianguo-main' AND name_chn = '太平天囯'"
      )

      metadata = db.execute("SELECT key, value FROM metadata").to_h do |row|
        [row.fetch("key"), row.fetch("value")]
      end
      assert_operator metadata.fetch("curated_eras").to_i, :>=, 5
      assert_equal "historical_eras.json", metadata.fetch("curated_era_filename")
    ensure
      db&.close
    end
  end

  private

  def synthetic_snapshot
    {
      "version" => EastAsianAuthorityUpdater::VERSION,
      "generated_at_utc" => Time.now.utc.iso8601,
      "rulers" => [
        {
          "qid" => "QTEST1",
          "source" => "wikidata_east_asia",
          "country" => "Japan",
          "label" => "孝徳天皇",
          "local_label" => "孝徳天皇",
          "han_names" => ["孝徳天皇"],
          "readings" => ["Emperor Kōtoku"],
          "reign_start_year" => 645,
          "reign_end_year" => 654,
          "positions" => ["Emperor of Japan"],
          "source_url" => "https://www.wikidata.org/wiki/QTEST1",
          "provenance" => ["Wikidata CC0"]
        },
        {
          "qid" => "QJIMMU",
          "source" => "wikidata_east_asia",
          "country" => "Japan",
          "label" => "神武天皇",
          "local_label" => "神武天皇",
          "han_names" => ["神武天皇", "彦火火出見"],
          "readings" => ["Emperor Jimmu"],
          "reign_start_year" => -660,
          "reign_end_year" => -585,
          "chronology_confidence" => "traditional_or_legendary",
          "chronology_note" => "Wikipedia's ruler list explicitly flags this chronology as legendary, disputed, or traditional.",
          "positions" => ["Emperor of Japan"],
          "source_url" => "https://www.wikidata.org/wiki/QJIMMU",
          "provenance" => ["Wikidata CC0", "Wikipedia ruler list (CC BY-SA 4.0)"]
        }
      ],
      "eras" => [
        {
          "qid" => "QERA1",
          "source" => "wikidata_east_asia",
          "country" => "Japan",
          "origin_country" => "Japan",
          "label" => "大化",
          "local_label" => "Taika",
          "han_names" => ["大化"],
          "readings" => ["Taika"],
          "start_year" => 645,
          "end_year" => 650,
          "local_use_start_year" => 645,
          "local_use_end_year" => 650,
          "adopted_from_foreign" => false,
          "ruler_qids" => ["QTEST1"],
          "source_url" => "https://www.wikidata.org/wiki/QERA1",
          "provenance" => ["Wikidata CC0"]
        },
        {
          "qid" => "WP-Korea-gaeguk",
          "source" => "wikipedia_era_list",
          "country" => "Korea",
          "origin_country" => "Korea",
          "label" => "Gaeguk",
          "han_names" => ["開國"],
          "readings" => ["Gaeguk"],
          "start_year" => 1894,
          "end_year" => 1895,
          "epoch_start_year" => 1392,
          "local_use_start_year" => 1894,
          "local_use_end_year" => 1895,
          "adopted_from_foreign" => false,
          "ruler_qids" => [],
          "source_url" => "https://en.wikipedia.org/wiki/Korean_era_name",
          "provenance" => ["Wikipedia era list (CC BY-SA 4.0)"]
        },
        {
          "qid" => "WP-Korea-test",
          "source" => "wikipedia_era_list",
          "country" => "Korea",
          "origin_country" => "China",
          "label" => "Yeongnak (Yongle)",
          "han_names" => ["永樂"],
          "readings" => ["Yeongnak (Yongle)"],
          "start_year" => nil,
          "end_year" => nil,
          "local_use_start_year" => 1403,
          "local_use_end_year" => 1418,
          "adopted_from_foreign" => true,
          "ruler_qids" => [],
          "source_url" => "https://en.wikipedia.org/wiki/Korean_era_name",
          "provenance" => ["Wikipedia era list (CC BY-SA 4.0)"]
        }
      ]
    }
  end
end
