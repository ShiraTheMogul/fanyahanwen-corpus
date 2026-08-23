# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

class HistoricalPersonRepositoryTest < ActiveSupport::TestCase
  test "CBDB author page data exposes names dynasty addresses and offices" do
    Dir.mktmpdir do |directory|
      path = Pathname(directory).join("cbdb.sqlite3")
      db = SQLite3::Database.new(path.to_s)
      db.execute_batch <<~SQL
        CREATE TABLE BIOG_MAIN (
          c_personid INTEGER PRIMARY KEY,
          c_name_chn TEXT,
          c_name TEXT,
          c_dy INTEGER,
          c_birthyear INTEGER,
          c_deathyear INTEGER,
          c_index_addr_id INTEGER
        );
        CREATE TABLE DYNASTIES (c_dy INTEGER PRIMARY KEY, c_dynasty TEXT, c_dynasty_chn TEXT);
        CREATE TABLE ALTNAME_DATA (c_personid INTEGER, c_alt_name_chn TEXT, c_alt_name_type_code INTEGER);
        CREATE TABLE ADDR_CODES (c_addr_id INTEGER PRIMARY KEY, c_name_chn TEXT);
        CREATE TABLE BIOG_ADDR_DATA (c_personid INTEGER, c_addr_id INTEGER, c_firstyear INTEGER, c_lastyear INTEGER);
        CREATE TABLE OFFICE_CODES (c_office_id INTEGER PRIMARY KEY, c_office_chn TEXT);
        CREATE TABLE POSTED_TO_OFFICE_DATA (c_personid INTEGER, c_office_id INTEGER, c_firstyear INTEGER, c_lastyear INTEGER);
      SQL
      db.execute("INSERT INTO BIOG_MAIN VALUES (1, '司馬遷', 'Sima Qian', 1, -145, -86, 10)")
      db.execute("INSERT INTO DYNASTIES VALUES (1, 'Western Han', '西漢')")
      db.execute("INSERT INTO ALTNAME_DATA VALUES (1, '太史公', 0)")
      db.execute("INSERT INTO ADDR_CODES VALUES (10, '龍門')")
      db.execute("INSERT INTO ADDR_CODES VALUES (11, '長安')")
      db.execute("INSERT INTO BIOG_ADDR_DATA VALUES (1, 11, -110, -100)")
      db.execute("INSERT INTO OFFICE_CODES VALUES (20, '太史令')")
      db.execute("INSERT INTO POSTED_TO_OFFICE_DATA VALUES (1, 20, -108, -91)")
      db.close

      store = HistoricalAuthorityStore.new(
        cbdb_path: path,
        cbdb_release: {},
        lookup_path: nil,
        historical_path: nil,
        cache_store: CorpusSearch::CacheStore.new(root: Pathname(directory).join("cache")),
        logger: nil
      )
      person = HistoricalPersonRepository.new(store: store).fetch(source: "cbdb", id: "1")

      assert_equal "司馬遷", person.fetch("label")
      assert_equal "Sima Qian", person.fetch("romanized")
      assert_equal "西漢", person.fetch("polity")
      assert_includes person.fetch("names").map { |row| row.fetch("name") }, "太史公"
      assert person.fetch("places").any? { |row| row["label"] == "龍門" && row["relation"] == "index_address" }
      assert person.fetch("places").any? { |row| row["label"] == "長安" && row["relation"] == "biographical_address" }
      assert person.fetch("offices").any? { |row| row["label"] == "太史令" && row["years"] == [-108, -91] }
      assert_includes person.fetch("source_citations").first, "Harvard University, Academia Sinica, & Peking University. (2025, May)."
    end
  end
  test "CBDB zero date sentinels are not displayed as year zero" do
    Dir.mktmpdir do |directory|
      path = Pathname(directory).join("cbdb.sqlite3")
      db = SQLite3::Database.new(path.to_s)
      db.execute("CREATE TABLE BIOG_MAIN (c_personid INTEGER PRIMARY KEY, c_name_chn TEXT, c_birthyear INTEGER, c_deathyear INTEGER)")
      db.execute("INSERT INTO BIOG_MAIN VALUES (2, '某人', 0, 0)")
      db.close

      store = HistoricalAuthorityStore.new(
        cbdb_path: path, cbdb_release: {}, lookup_path: nil, historical_path: nil,
        cache_store: CorpusSearch::CacheStore.new(root: Pathname(directory).join("cache")), logger: nil
      )
      person = HistoricalPersonRepository.new(store: store).fetch(source: "cbdb", id: "2")

      assert_nil person["year_start"]
      assert_nil person["year_end"]
      assert_nil person["date_label"]
    end
  end

  test "person candidate lookup queries CBDB directly and does not depend on automatic annotation" do
    Dir.mktmpdir do |directory|
      path = Pathname(directory).join("cbdb.sqlite3")
      db = SQLite3::Database.new(path.to_s)
      db.execute("CREATE TABLE BIOG_MAIN (c_personid INTEGER PRIMARY KEY, c_name_chn TEXT, c_name TEXT, c_birthyear INTEGER, c_deathyear INTEGER)")
      db.execute("CREATE TABLE ALTNAME_DATA (c_personid INTEGER, c_alt_name_chn TEXT, c_alt_name_type_code INTEGER)")
      db.execute("INSERT INTO BIOG_MAIN VALUES (551, '孔丘', 'Kong Qiu', -551, -479)")
      db.execute("INSERT INTO ALTNAME_DATA VALUES (551, '孔子', 0)")
      db.close

      store = HistoricalAuthorityStore.new(
        cbdb_path: path, cbdb_release: {}, lookup_path: nil, historical_path: nil,
        cache_store: CorpusSearch::CacheStore.new(root: Pathname(directory).join("cache")), logger: nil
      )
      repository = HistoricalPersonRepository.new(store: store)

      CbdbAutoAnnotator.stub(:call, ->(**) { raise "author lookup must not call the text annotator" }) do
        candidates = repository.find_candidates(names: ["孔丘"], metadata: { "period" => "周朝" }).candidates
        assert_equal 1, candidates.length
        assert_equal "551", candidates.first.fetch("id")
        assert_equal "cbdb", candidates.first.fetch("authority_source")
        assert_equal "high", candidates.first.fetch("confidence")
      end
    end
  end

end
