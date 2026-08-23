# frozen_string_literal: true

require_relative "../test_helper"
require "digest"
require "tmpdir"

class CbdbLookupIndexTest < ActiveSupport::TestCase
  test "builds a pointer cache without copying CBDB authority records" do
    Dir.mktmpdir do |directory|
      source = Pathname(directory).join("cbdb.sqlite3")
      build_source(source)
      cache_store = CorpusSearch::CacheStore.new(root: Pathname(directory).join("cache"))
      sha = Digest::SHA256.file(source).hexdigest

      result = CbdbLookupIndex.build_if_needed!(
        source_path: source,
        source_release: { "sha256" => sha },
        cache_store: cache_store,
        logger: nil
      )
      assert result.available?
      assert result.rebuilt?
      assert_equal 4, result.counts["names"]

      db = SQLite3::Database.new(result.path, readonly: true)
      tables = db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").flatten
      assert_equal %w[metadata names], tables
      assert_equal CbdbLookupIndex::VERSION.to_s, db.get_first_value("SELECT value FROM metadata WHERE key = 'version'")
      assert_includes db.execute("PRAGMA table_info(names)").map { |row| row[1].to_s }, "prefix"
      assert_equal 1, db.get_first_value("SELECT COUNT(*) FROM names WHERE kind = 'person' AND name_chn = '韓愈'")
      assert_equal 1, db.get_first_value("SELECT COUNT(*) FROM names WHERE kind = 'person' AND name_chn = '退之'")
      assert_equal 1, db.get_first_value("SELECT COUNT(*) FROM names WHERE kind = 'place' AND name_chn = '長安'")
      assert_equal 1, db.get_first_value("SELECT COUNT(*) FROM names WHERE kind = 'office' AND name_chn = '吏部尚書'")
    ensure
      db&.close
    end
  end

  test "rebuilds a legacy lookup cache even when it points at the same CBDB release" do
    Dir.mktmpdir do |directory|
      source = Pathname(directory).join("cbdb.sqlite3")
      build_source(source)
      cache_store = CorpusSearch::CacheStore.new(root: Pathname(directory).join("cache"))
      sha = Digest::SHA256.file(source).hexdigest
      legacy_path = CbdbLookupIndex.path(cache_store: cache_store)
      FileUtils.mkdir_p(legacy_path.dirname)
      build_legacy_lookup(legacy_path, sha)

      legacy_db = SQLite3::Database.new(legacy_path.to_s, readonly: true)
      refute_includes legacy_db.execute("PRAGMA table_info(names)").map { |row| row[1].to_s }, "prefix"
      legacy_db.close
      legacy_db = nil

      result = CbdbLookupIndex.build_if_needed!(
        source_path: source,
        source_release: { "sha256" => sha },
        cache_store: cache_store,
        logger: nil
      )

      assert result.rebuilt?
      rebuilt = SQLite3::Database.new(result.path, readonly: true)
      assert_equal CbdbLookupIndex::VERSION.to_s, rebuilt.get_first_value("SELECT value FROM metadata WHERE key = 'version'")
      assert_includes rebuilt.execute("PRAGMA table_info(names)").map { |row| row[1].to_s }, "prefix"
      assert_equal 1, rebuilt.get_first_value("SELECT COUNT(*) FROM names WHERE name_chn = '韓愈'")
    ensure
      legacy_db&.close
      rebuilt&.close
    end
  end

  private

  def build_source(path)
    db = SQLite3::Database.new(path.to_s)
    db.execute_batch <<~SQL
      CREATE TABLE BIOG_MAIN (c_personid INTEGER PRIMARY KEY, c_name_chn TEXT);
      CREATE TABLE ALTNAME_DATA (c_personid INTEGER, c_alt_name_chn TEXT);
      CREATE TABLE ADDR_CODES (c_addr_id INTEGER PRIMARY KEY, c_name_chn TEXT, c_firstyear INTEGER, c_lastyear INTEGER);
      CREATE TABLE OFFICE_CODES (c_office_id INTEGER PRIMARY KEY, c_office_chn TEXT);
      INSERT INTO BIOG_MAIN VALUES (1, '韓愈');
      INSERT INTO ALTNAME_DATA VALUES (1, '退之');
      INSERT INTO ADDR_CODES VALUES (10, '長安', 0, 1900);
      INSERT INTO OFFICE_CODES VALUES (20, '吏部尚書');
    SQL
  ensure
    db&.close
  end

  def build_legacy_lookup(path, source_sha)
    db = SQLite3::Database.new(path.to_s)
    db.execute_batch <<~SQL
      CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE names (
        name_length INTEGER NOT NULL,
        name_chn TEXT NOT NULL,
        kind TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        primary_name INTEGER NOT NULL DEFAULT 0
      );
    SQL
    db.execute("INSERT INTO metadata (key, value) VALUES ('version', '1')")
    db.execute("INSERT INTO metadata (key, value) VALUES ('source_sha256', ?)", [source_sha])
  ensure
    db&.close
  end
end
