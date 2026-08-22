# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

class EraCalendarConverterTest < ActiveSupport::TestCase
  test "converts curated era expressions to absolute years" do
    Dir.mktmpdir do |directory|
      store = build_store(directory)

      taiping = EraCalendarConverter.convert(
        direction: "era_to_absolute",
        input: "太平天國癸好三年",
        country: "China",
        polity: "太平天國",
        store: store
      )
      assert_equal 1853, taiping.dig("resolution", "year_start")

      daxi = EraCalendarConverter.convert(
        direction: "era_to_absolute",
        input: "大順三年",
        country: "China",
        polity: "大西",
        store: store
      )
      assert_equal 1646, daxi.dig("resolution", "year_start")
    end
  end

  test "converts absolute years back to curated era forms and Taiping branch characters" do
    Dir.mktmpdir do |directory|
      store = build_store(directory)

      taiping = EraCalendarConverter.convert(
        direction: "absolute_to_era",
        input: "1853",
        country: "China",
        polity: "太平天國",
        store: store
      )
      match = taiping.fetch("matches").find { |row| row.fetch("id") == "china-taiping-tianguo-main" }
      assert_equal 3, match.fetch("year_number")
      assert_equal "癸好", match.fetch("sexagenary")
      assert_equal "太平天國癸好三年", match.fetch("expression")

      daxi = EraCalendarConverter.convert(
        direction: "absolute_to_era",
        input: "1646",
        country: "China",
        polity: "大西",
        store: store
      )
      daxi_match = daxi.fetch("matches").find { |row| row.fetch("expression") == "大順三年" }
      assert daxi_match
      assert_includes Array(daxi_match["rulers"]).map { |row| row["han_name"] }, "張獻忠"

      daxi_fourth = EraCalendarConverter.convert(
        direction: "absolute_to_era",
        input: "1647",
        country: "China",
        polity: "大西",
        store: store
      )
      assert daxi_fourth.fetch("matches").any? { |row| row.fetch("expression") == "大順四年" }
    end
  end

  test "reverse lookup derives the origin epoch for a locally adopted Japanese era" do
    Dir.mktmpdir do |directory|
      store = build_store(directory)
      result = EraCalendarConverter.convert(
        direction: "absolute_to_era",
        input: "1935 CE",
        country: "Korea",
        store: store
      )

      adoption = result.fetch("matches").find { |row| row.fetch("id") == "WP-Korea-showa" }
      assert adoption
      assert_equal 10, adoption.fetch("year_number")
      assert_equal "昭和十年", adoption.fetch("expression")
      assert_equal true, adoption.fetch("adopted_from_foreign")
    end
  end

  test "Taiping Tian-de is absent from curated reverse and forward authority aliases" do
    Dir.mktmpdir do |directory|
      store = build_store(directory)
      forward = EraCalendarConverter.convert(
        direction: "era_to_absolute",
        input: "天德三年",
        country: "China",
        polity: "太平天國",
        store: store
      )
      assert_nil forward["resolution"]

      disputed_daxi = EraCalendarConverter.convert(
        direction: "era_to_absolute",
        input: "義武二年",
        country: "China",
        polity: "大西",
        store: store
      )
      assert_nil disputed_daxi["resolution"]

      reverse = EraCalendarConverter.convert(
        direction: "absolute_to_era",
        input: "1853",
        country: "China",
        polity: "太平天國",
        store: store
      )
      refute reverse.fetch("matches").any? { |row| row.fetch("name_chn") == "天德" }
    end
  end

  test "CBDB reverse results show dynasty English labels and conservative ruler context" do
    Dir.mktmpdir do |directory|
      store = build_cbdb_store(directory)

      jin = EraCalendarConverter.convert(
        direction: "absolute_to_era",
        input: "300",
        country: "China",
        store: store
      )
      yongkang = jin.fetch("matches").find { |row| row.fetch("expression") == "永康元年" }
      assert_equal "西晉 (Western Jin)", yongkang.fetch("polity_display")
      assert_equal "惠帝", yongkang.dig("rulers", 0, "han_name")
      assert_equal "Hui Di", yongkang.dig("rulers", 0, "english_label")
      assert_includes yongkang.dig("rulers", 0, "han_names"), "司馬衷"

      qing = EraCalendarConverter.convert(
        direction: "absolute_to_era",
        input: "1894",
        country: "China",
        store: store
      )
      guangxu = qing.fetch("matches").find { |row| row.fetch("expression") == "光緒二十年" }
      assert_equal "清 (Qing)", guangxu.fetch("polity_display")
      assert_equal "光緒帝", guangxu.dig("rulers", 0, "han_name")
      assert_equal "Guangxu Emperor", guangxu.dig("rulers", 0, "english_label")
    end
  end

  test "reverse results show Han-first polity labels and active rulers" do
    Dir.mktmpdir do |directory|
      store = build_store(directory)

      korea = EraCalendarConverter.convert(
        direction: "absolute_to_era",
        input: "1894",
        country: "Korea",
        store: store
      )
      gaeguk = korea.fetch("matches").find { |row| row.fetch("id") == "QGAEGUK" }
      assert_equal "韓國 (Korea)", gaeguk.fetch("country_display")
      assert_includes gaeguk.fetch("polity_displays"), "朝鮮王朝 (Joseon dynasty)"
      assert_equal "高宗", gaeguk.dig("rulers", 0, "han_name")
      assert_equal "Gojong", gaeguk.dig("rulers", 0, "english_label")

      vietnam = EraCalendarConverter.convert(
        direction: "absolute_to_era",
        input: "1894",
        country: "Vietnam",
        store: store
      )
      thanh_thai = vietnam.fetch("matches").find { |row| row.fetch("id") == "QTHANHTHAIERA" }
      assert_equal "越南 (Vietnam)", thanh_thai.fetch("country_display")
      assert_includes thanh_thai.fetch("polity_displays"), "阮朝 (Nguyễn dynasty)"
      assert_equal "成泰", thanh_thai.dig("rulers", 0, "han_name")
      assert_equal "Thành Thái", thanh_thai.dig("rulers", 0, "english_label")
    end
  end

  private

  def build_cbdb_store(directory)
    require "sqlite3"
    path = Pathname(directory).join("cbdb.sqlite3")
    db = SQLite3::Database.new(path.to_s)
    db.execute_batch <<~SQL
      CREATE TABLE NIAN_HAO (
        c_nianhao_id INTEGER PRIMARY KEY,
        c_dy INTEGER,
        c_dynasty_chn TEXT,
        c_nianhao_chn TEXT,
        c_nianhao_pin TEXT,
        c_firstyear INTEGER,
        c_lastyear INTEGER
      );
      CREATE TABLE DYNASTIES (
        c_dy INTEGER PRIMARY KEY,
        c_dynasty TEXT,
        c_dynasty_chn TEXT,
        c_start INTEGER,
        c_end INTEGER
      );
      CREATE TABLE BIOG_MAIN (
        c_personid INTEGER PRIMARY KEY,
        c_name_chn TEXT,
        c_name TEXT,
        c_dy INTEGER,
        c_birthyear INTEGER,
        c_deathyear INTEGER
      );
      CREATE TABLE STATUS_DATA (
        c_personid INTEGER,
        c_status_code INTEGER,
        c_firstyear INTEGER,
        c_lastyear INTEGER
      );
      CREATE TABLE ALTNAME_DATA (
        c_personid INTEGER,
        c_alt_name_chn TEXT,
        c_alt_name TEXT,
        c_alt_name_type_code INTEGER,
        c_sequence INTEGER
      );
    SQL
    db.execute("INSERT INTO DYNASTIES VALUES (23, 'Western Jin', '西晉', 265, 317)")
    db.execute("INSERT INTO DYNASTIES VALUES (20, 'Qing', '清', 1644, 1911)")
    db.execute("INSERT INTO NIAN_HAO VALUES (1, 23, '西晉', '永康', 'Yongkang', 300, 301)")
    db.execute("INSERT INTO NIAN_HAO VALUES (2, 20, '清', '光緒', 'Guangxu', 1875, 1908)")
    db.execute("INSERT INTO BIOG_MAIN VALUES (10, '司馬炎', 'Sima Yan', 23, 236, 290)")
    db.execute("INSERT INTO BIOG_MAIN VALUES (11, '司馬衷', 'Sima Zhong', 23, 259, 306)")
    db.execute("INSERT INTO BIOG_MAIN VALUES (12, '司馬熾', 'Sima Zhi', 23, 283, 313)")
    db.execute("INSERT INTO STATUS_DATA VALUES (10, 26, 0, 0)")
    db.execute("INSERT INTO STATUS_DATA VALUES (11, 26, 0, 0)")
    db.execute("INSERT INTO STATUS_DATA VALUES (12, 26, 0, 0)")
    db.execute("INSERT INTO ALTNAME_DATA VALUES (11, '孝惠皇帝', 'Emperor Xiaohui', 6, 1)")
    db.execute("INSERT INTO ALTNAME_DATA VALUES (11, '惠帝', 'Hui Di', 0, 2)")
    db.close

    HistoricalAuthorityStore.new(
      cbdb_path: path,
      cbdb_release: {},
      lookup_path: nil,
      historical_path: nil,
      cache_store: CorpusSearch::CacheStore.new(root: Pathname(directory).join("cache")),
      logger: nil
    )
  end

  def build_store(directory)
    cache_store = CorpusSearch::CacheStore.new(root: Pathname(directory).join("cache"))
    snapshot = {
      "version" => EastAsianAuthorityUpdater::VERSION,
      "generated_at_utc" => Time.now.utc.iso8601,
      "rulers" => [
        {
          "qid" => "QGOJONG",
          "source" => "wikidata_east_asia",
          "country" => "Korea",
          "label" => "고종",
          "local_label" => "고종",
          "han_names" => ["高宗", "李㷩"],
          "readings" => ["Gojong"],
          "reign_start_year" => 1864,
          "reign_end_year" => 1907,
          "polities" => ["Joseon"],
          "source_url" => "https://www.wikidata.org/wiki/QGOJONG"
        },
        {
          "qid" => "QTHANHTHAI",
          "source" => "wikidata_east_asia",
          "country" => "Vietnam",
          "label" => "Thành Thái",
          "local_label" => "Thành Thái",
          "han_names" => ["成泰", "阮福昭"],
          "readings" => ["Thành Thái"],
          "reign_start_year" => 1889,
          "reign_end_year" => 1907,
          "polities" => ["Nguyễn dynasty"],
          "source_url" => "https://www.wikidata.org/wiki/QTHANHTHAI"
        }
      ],
      "eras" => [
        {
          "qid" => "QGAEGUK",
          "source" => "wikipedia_era_list",
          "country" => "Korea",
          "origin_country" => "Korea",
          "label" => "Gaeguk",
          "local_label" => "Gaeguk",
          "han_names" => ["開國"],
          "readings" => ["Gaeguk"],
          "start_year" => 1392,
          "end_year" => 1895,
          "epoch_start_year" => 1392,
          "local_use_start_year" => 1894,
          "local_use_end_year" => 1895,
          "adopted_from_foreign" => false,
          "polities" => ["Joseon"],
          "ruler_qids" => ["QGOJONG"],
          "source_url" => "https://en.wikipedia.org/wiki/Korean_era_name"
        },
        {
          "qid" => "QTHANHTHAIERA",
          "source" => "wikipedia_era_list",
          "country" => "Vietnam",
          "origin_country" => "Vietnam",
          "label" => "Thành Thái",
          "local_label" => "Thành Thái",
          "han_names" => ["成泰"],
          "readings" => ["Thành Thái"],
          "start_year" => 1889,
          "end_year" => 1907,
          "epoch_start_year" => 1889,
          "local_use_start_year" => 1889,
          "local_use_end_year" => 1907,
          "adopted_from_foreign" => false,
          "polities" => ["Nguyễn dynasty"],
          "ruler_qids" => ["QTHANHTHAI"],
          "source_url" => "https://en.wikipedia.org/wiki/Vietnamese_era_name"
        },
        {
          "qid" => "QSHOWA",
          "source" => "wikidata_east_asia",
          "country" => "Japan",
          "origin_country" => "Japan",
          "label" => "昭和",
          "han_names" => ["昭和"],
          "readings" => ["Shōwa"],
          "start_year" => 1926,
          "end_year" => 1989,
          "epoch_start_year" => 1926,
          "local_use_start_year" => 1926,
          "local_use_end_year" => 1989,
          "adopted_from_foreign" => false,
          "ruler_qids" => [],
          "source_url" => "https://www.wikidata.org/wiki/QSHOWA"
        },
        {
          "qid" => "WP-Korea-showa",
          "source" => "wikipedia_era_list",
          "country" => "Korea",
          "origin_country" => "Japan",
          "label" => "Shōwa",
          "han_names" => ["昭和"],
          "readings" => ["Shōwa"],
          "start_year" => nil,
          "end_year" => nil,
          "epoch_start_year" => nil,
          "local_use_start_year" => 1926,
          "local_use_end_year" => 1945,
          "adopted_from_foreign" => true,
          "ruler_qids" => [],
          "source_url" => "https://en.wikipedia.org/wiki/Korean_era_name"
        }
      ]
    }
    cache_store.write_json(EastAsianAuthorityUpdater::SNAPSHOT_PATH, snapshot)
    index = HistoricalAuthorityIndex.build_if_needed!(cache_store: cache_store, snapshot: snapshot, logger: nil)
    HistoricalAuthorityStore.new(
      cbdb_path: nil,
      cbdb_release: {},
      lookup_path: nil,
      historical_path: index.path,
      cache_store: cache_store,
      logger: nil
    )
  end
end
