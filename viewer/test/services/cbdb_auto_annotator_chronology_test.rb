# frozen_string_literal: true

require_relative "../test_helper"
require "digest"
require "tmpdir"

class CbdbAutoAnnotatorChronologyTest < ActiveSupport::TestCase
  test "CBDB author lifespan supplies a writing range and blocks people from the future" do
    Dir.mktmpdir do |directory|
      source = Pathname(directory).join("cbdb.sqlite3")
      build_cbdb(source)
      store = cbdb_store(directory, source)

      result = CbdbAutoAnnotator.call(
        text: "二十。孔丘曰。",
        metadata: { "corpus_root" => "中國漢文", "period" => "先秦", "authors" => ["孔丘"] },
        store: store
      )

      assert_equal(-551, result.context.fetch("year_start"))
      assert_equal(-479, result.context.fetch("year_end"))
      refute result.items.any? { |item| item.fetch("text") == "二十" }, "a Ming person must not appear inside an author-dated pre-Qin work"

      confucius = result.items.find { |item| item.fetch("text") == "孔丘" }
      assert confucius
      assert_equal(-515, confucius.fetch("candidates").first.fetch("representative_year"))
    end
  end



  test "person names without any temporal anchor are not automatically annotated" do
    Dir.mktmpdir do |directory|
      source = Pathname(directory).join("cbdb.sqlite3")
      build_cbdb(source)
      store = cbdb_store(directory, source)

      result = CbdbAutoAnnotator.call(
        text: "子曰：學而時習之。",
        metadata: { "corpus_root" => "中國漢文", "period" => "先秦" },
        store: store
      )

      refute result.items.any? { |item| item.fetch("text") == "子" },
        "a bare CBDB identity with no dates or recognised polity must not turn ordinary 子曰 into a person annotation"
    end
  end

  test "CBDB dynasty supplies a fallback period and blocks a future polity" do
    Dir.mktmpdir do |directory|
      source = Pathname(directory).join("cbdb.sqlite3")
      build_cbdb(source)
      store = cbdb_store(directory, source)

      ancient = CbdbAutoAnnotator.call(
        text: "權量曰。",
        metadata: { "corpus_root" => "中國漢文", "period" => "先秦" },
        store: store
      )
      refute ancient.items.any? { |item| item.fetch("text") == "權量" },
        "a Qing person with no personal dates must not appear in a pre-Qin work"

      qing = CbdbAutoAnnotator.call(
        text: "權量曰。",
        metadata: { "corpus_root" => "中國漢文", "period" => "清" },
        store: store
      )
      item = qing.items.find { |row| row.fetch("text") == "權量" }
      assert item, "the same person remains eligible once the text reaches the Qing period"
      candidate = item.fetch("candidates").first
      assert_equal "清", candidate.fetch("polity")
      assert_equal 1778, candidate.fetch("representative_year")
      assert_nil candidate["year_start"], "the polity fallback must not masquerade as a personal birth year"
      assert_nil candidate["year_end"], "the polity fallback must not masquerade as a personal death year"
    end
  end

  test "ordinary CBDB era names are exposed as hover conversions" do
    Dir.mktmpdir do |directory|
      source = Pathname(directory).join("cbdb.sqlite3")
      build_cbdb(source)
      store = cbdb_store(directory, source)

      result = CbdbAutoAnnotator.call(
        text: "是爲序。康熙五十五年。",
        metadata: { "corpus_root" => "中國漢文", "period" => "清" },
        store: store
      )

      assert_equal 1716, result.context.fetch("year_start")
      assert_equal 1716, result.context.fetch("year_end")
      date = result.context.fetch("regnal_dates").find { |row| row.fetch("authority_name") == "康熙" }
      assert date
      assert_equal 1716, date.fetch("absolute_year")
      assert_equal "康熙五十五年", date.fetch("text")
    end
  end

  test "regnal dates are exposed for hover conversion and one compatible date can tighten the work date" do
    Dir.mktmpdir do |directory|
      store = historical_store(directory)
      text = "是爲序。太平天國癸好三年。"
      result = CbdbAutoAnnotator.call(
        text: text,
        metadata: { "corpus_root" => "中國漢文", "period" => "太平天國", "polity" => "太平天國" },
        store: store
      )

      assert_equal 1853, result.context.fetch("year_start")
      assert_equal 1853, result.context.fetch("year_end")
      dates = result.context.fetch("regnal_dates")
      date = dates.find { |row| row.fetch("absolute_year") == 1853 }
      assert date
      assert_equal "太平天國癸好三年", text.each_char.to_a[date.fetch("start")...date.fetch("end")].join
      assert_equal "太平天國", date.fetch("authority_name")
    end
  end

  test "Dongning Yongli continuation keeps the 1647 epoch through 1683" do
    Dir.mktmpdir do |directory|
      store = historical_store(directory)
      result = CbdbAutoAnnotator.call(
        text: "永曆二十五年。",
        metadata: { "corpus_root" => "中國漢文", "period" => "東寧", "polity" => "東寧" },
        store: store
      )

      assert_equal 1671, result.context.fetch("year_start")
      assert_equal 1671, result.context.fetch("year_end")
      date = result.context.fetch("regnal_dates").first
      assert_equal 1671, date.fetch("absolute_year")
      assert_equal "永曆二十五年", date.fetch("text")
    end
  end

  test "a quoted but period-incompatible regnal date is converted without dating the work" do
    Dir.mktmpdir do |directory|
      store = historical_store(directory)
      result = CbdbAutoAnnotator.call(
        text: "永曆九年事如此。",
        metadata: { "corpus_root" => "中國漢文", "period" => "東寧", "polity" => "東寧" },
        store: store
      )

      date = result.context.fetch("regnal_dates").find { |row| row.fetch("absolute_year") == 1655 }
      assert date, "the hover conversion should still explain a quoted historical date"
      assert_equal 1661, result.context.fetch("year_start")
      assert_equal 1683, result.context.fetch("year_end")
    end
  end

  private

  def build_cbdb(path)
    db = SQLite3::Database.new(path.to_s)
    db.execute_batch <<~SQL
      CREATE TABLE BIOG_MAIN (
        c_personid INTEGER PRIMARY KEY,
        c_name_chn TEXT,
        c_birthyear INTEGER,
        c_deathyear INTEGER,
        c_dy INTEGER
      );
      CREATE TABLE ALTNAME_DATA (c_personid INTEGER, c_alt_name_chn TEXT);
      CREATE TABLE ADDR_CODES (c_addr_id INTEGER PRIMARY KEY, c_name_chn TEXT, c_firstyear INTEGER, c_lastyear INTEGER);
      CREATE TABLE OFFICE_CODES (c_office_id INTEGER PRIMARY KEY, c_office_chn TEXT);
      CREATE TABLE DYNASTIES (
        c_dy INTEGER PRIMARY KEY,
        c_dynasty_chn TEXT
      );
      CREATE TABLE NIAN_HAO (
        c_nianhao_id INTEGER PRIMARY KEY,
        c_dynasty_chn TEXT,
        c_nianhao_chn TEXT,
        c_firstyear INTEGER,
        c_lastyear INTEGER
      );
      INSERT INTO BIOG_MAIN VALUES (1, '孔丘', -551, -479, NULL);
      INSERT INTO BIOG_MAIN VALUES (2, '二十', 1482, 1529, NULL);
      INSERT INTO BIOG_MAIN VALUES (3, '子', 0, 0, NULL);
      INSERT INTO BIOG_MAIN VALUES (609902, '權量', NULL, NULL, 20);
      INSERT INTO DYNASTIES VALUES (20, '清');
      INSERT INTO NIAN_HAO VALUES (100, '清', '康熙', 1662, 1722);
    SQL
  ensure
    db&.close
  end


  def cbdb_store(directory, source)
    cache_store = CorpusSearch::CacheStore.new(root: Pathname(directory).join("cache"))
    sha = Digest::SHA256.file(source).hexdigest
    lookup = CbdbLookupIndex.build_if_needed!(
      source_path: source,
      source_release: { "sha256" => sha },
      cache_store: cache_store,
      logger: nil
    )
    HistoricalAuthorityStore.new(
      cbdb_path: source,
      cbdb_release: { "sha256" => sha },
      lookup_path: lookup.path,
      historical_path: nil,
      cache_store: cache_store,
      logger: nil
    )
  end

  def historical_store(directory)
    cache_store = CorpusSearch::CacheStore.new(root: Pathname(directory).join("cache"))
    snapshot = {
      "version" => EastAsianAuthorityUpdater::VERSION,
      "generated_at_utc" => Time.now.utc.iso8601,
      "rulers" => [],
      "eras" => []
    }
    cache_store.write_json(EastAsianAuthorityUpdater::SNAPSHOT_PATH, snapshot)
    historical = HistoricalAuthorityIndex.build_if_needed!(cache_store: cache_store, snapshot: snapshot, logger: nil)
    HistoricalAuthorityStore.new(
      cbdb_path: nil,
      cbdb_release: {},
      lookup_path: nil,
      historical_path: historical.path,
      cache_store: cache_store,
      logger: nil
    )
  end
end
