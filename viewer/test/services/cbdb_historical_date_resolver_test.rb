# frozen_string_literal: true

require_relative "../test_helper"
require "digest"
require "tmpdir"

class CbdbHistoricalDateResolverTest < ActiveSupport::TestCase
  test "compatibility resolver delegates reused era names to the unified authority context" do
    Dir.mktmpdir do |directory|
      cbdb = Pathname(directory).join("cbdb.sqlite3")
      db = SQLite3::Database.new(cbdb.to_s)
      db.execute_batch <<~SQL
        CREATE TABLE BIOG_MAIN (c_personid INTEGER PRIMARY KEY, c_name_chn TEXT);
        CREATE TABLE NIAN_HAO (c_nianhao_id INTEGER PRIMARY KEY, c_dynasty_chn TEXT, c_nianhao_chn TEXT, c_firstyear INTEGER, c_lastyear INTEGER);
        INSERT INTO NIAN_HAO VALUES (1, '東漢', '元和', 84, 87);
        INSERT INTO NIAN_HAO VALUES (2, '唐', '元和', 806, 820);
      SQL
      db.close
      db = nil

      cache_store = CorpusSearch::CacheStore.new(root: Pathname(directory).join("cache"))
      store = HistoricalAuthorityStore.new(
        cbdb_path: cbdb,
        cbdb_release: { "sha256" => Digest::SHA256.file(cbdb).hexdigest },
        lookup_path: nil,
        historical_path: nil,
        cache_store: cache_store,
        logger: nil
      )
      resolver = CbdbHistoricalDateResolver.new(store: store)
      result = resolver.resolve("元和三年", "corpus_root" => "中國漢文", "period" => "唐")
      assert_equal 808, result.year_start
    ensure
      db&.close
    end
  end
end
