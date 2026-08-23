# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

class AuthorityHanVariantRegistryTest < ActiveSupport::TestCase
  test "controlled authority orthography never touches VariantMapping" do
    registry = AuthorityHanVariantRegistry.instance

    VariantMapping.stub(:connection, -> { flunk "Authority orthography touched VariantMapping" }) do
      assert registry.equivalent?("國", "国")
      assert registry.forms_for("國").include?("国")
      refute registry.equivalent?("發", "髮"), "two traditional forms sharing a simplified form must not become aliases"
    end
  end

  test "historical date resolver construction stays off the database variant graph" do
    resolver = nil
    VariantMapping.stub(:connection, -> { flunk "HistoricalDateResolver touched VariantMapping" }) do
      resolver = HistoricalDateResolver.new(store: HistoricalAuthorityStore.default)
      forms = resolver.instance_variable_get(:@expander).expand("國德").map(&:name)
      assert_includes forms, "国德"
    end

    registry = resolver.instance_variable_get(:@expander).instance_variable_get(:@registry)
    assert_instance_of AuthorityHanVariantRegistry, registry
  end

  test "automatic annotator construction stays off the database variant graph" do
    annotator = nil
    VariantMapping.stub(:connection, -> { flunk "CbdbAutoAnnotator touched VariantMapping" }) do
      annotator = CbdbAutoAnnotator.new(text: "司馬遷", metadata: {}, store: HistoricalAuthorityStore.default)
    end

    assert_instance_of AuthorityHanVariantRegistry, annotator.instance_variable_get(:@equivalence)
  end


  test "era calendar forward conversion never touches VariantMapping" do
    unavailable_store = Object.new
    def unavailable_store.available? = false

    VariantMapping.stub(:connection, -> { flunk "EraCalendarConverter forward path touched VariantMapping" }) do
      result = EraCalendarConverter.new(store: unavailable_store).convert(
        direction: "era_to_absolute",
        input: "永昌三年"
      )
      assert_equal "era_to_absolute", result["direction"]
      assert_equal false, result["authority_available"]
    end
  end

  test "era calendar helper stays off the database variant graph" do
    converter = nil
    VariantMapping.stub(:connection, -> { flunk "EraCalendarConverter touched VariantMapping" }) do
      converter = EraCalendarConverter.new(store: HistoricalAuthorityStore.default)
      assert_equal ["國德"], converter.send(:compact_equivalent_names, ["國德", "国德"])
    end
  end
  test "historical authority availability fingerprints static authority mappings, not VariantMapping" do
    Dir.mktmpdir do |directory|
      directory = Pathname(directory)
      cache_store = CorpusSearch::CacheStore.new(root: directory.join("cache"))
      snapshot = EastAsianAuthorityUpdater.current(cache_store: cache_store)
      index = HistoricalAuthorityIndex.new(cache_store: cache_store, logger: nil)
      fingerprint = index.send(:source_fingerprint, snapshot)

      historical = directory.join("historical.sqlite3")
      db = SQLite3::Database.new(historical.to_s)
      db.execute("CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
      db.execute("INSERT INTO metadata (key, value) VALUES ('version', ?)", [HistoricalAuthorityIndex::VERSION.to_s])
      db.execute("INSERT INTO metadata (key, value) VALUES ('fingerprint', ?)", [fingerprint])
      db.close

      store = HistoricalAuthorityStore.new(
        cbdb_path: nil,
        cbdb_release: {},
        lookup_path: nil,
        historical_path: historical,
        cache_store: cache_store,
        logger: nil
      )

      CorpusSearch::CharacterEquivalenceRegistry.stub(:version_for, ->(*) { flunk "runtime authority availability touched the broad VariantMapping fingerprint" }) do
        assert store.historical_available?
        assert store.available?
      end
    end
  end

  test "automatic annotation lookup failures remain observable" do
    store = Object.new
    store.define_singleton_method(:available?) { true }
    store.define_singleton_method(:metadata) { {} }
    store.define_singleton_method(:lookup_available?) { true }
    store.define_singleton_method(:historical_available?) { false }
    store.define_singleton_method(:with_database) { |&block| raise SQLite3::SQLException, "broken authority index" }

    annotator = CbdbAutoAnnotator.new(text: "司馬遷", metadata: {}, store: store)
    error = assert_raises(SQLite3::SQLException) { annotator.call }
    assert_match(/broken authority index/, error.message)
  end

end
