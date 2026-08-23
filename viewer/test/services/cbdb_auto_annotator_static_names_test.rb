# frozen_string_literal: true

require_relative "../test_helper"
require "sqlite3"

class CbdbAutoAnnotatorStaticNamesTest < ActiveSupport::TestCase
  UnavailableStore = Struct.new(:metadata) do
    def available? = false
    def lookup_available? = false
    def historical_available? = false
  end

  class HistoricalFixtureStore
    def initialize
      @db = SQLite3::Database.new(":memory:")
      @db.results_as_hash = true
      @db.execute("ATTACH DATABASE ':memory:' AS historical")
      @db.execute_batch <<~SQL
        CREATE TABLE historical.people (
          source TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          country TEXT,
          label TEXT,
          local_label TEXT,
          romanized TEXT,
          year_start INTEGER,
          year_end INTEGER,
          date_label TEXT,
          polity TEXT,
          roles TEXT,
          places TEXT,
          source_url TEXT,
          source_citations TEXT,
          chronology_confidence TEXT,
          external_ids TEXT,
          shang_diviner INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (source, entity_id)
        );
        CREATE TABLE historical.names (
          prefix TEXT NOT NULL,
          name_length INTEGER NOT NULL,
          name_chn TEXT NOT NULL,
          source TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          primary_name INTEGER NOT NULL DEFAULT 0,
          explicit_name INTEGER NOT NULL DEFAULT 0,
          derivation TEXT NOT NULL,
          PRIMARY KEY (prefix, name_chn, source, entity_id)
        );
      SQL
    end

    def add_person(name, id: name, year_start: nil, year_end: nil)
      @db.execute(
        "INSERT INTO historical.people (source, entity_id, country, label, year_start, year_end, roles) VALUES (?, ?, ?, ?, ?, ?, ?)",
        ["fixture", id, "China", name, year_start, year_end, "ruler"]
      )
      @db.execute(
        "INSERT INTO historical.names (prefix, name_length, name_chn, source, entity_id, primary_name, explicit_name, derivation) VALUES (?, 1, ?, ?, ?, 1, 1, 'fixture_explicit')",
        [name, name, "fixture", id]
      )
    end

    def available? = true
    def lookup_available? = false
    def historical_available? = true
    def metadata = { "historical_available" => true }
    def with_database = yield(@db)
    def close = @db.close
  end

  test "prepended annotator returns the base result type when authority data are unavailable" do
    result = CbdbAutoAnnotator.call(
      text: "孔子曰",
      metadata: { "period" => "春秋" },
      store: UnavailableStore.new({})
    )

    assert_instance_of CbdbAutoAnnotator::Result, result
    assert_equal [], result.items
    assert_equal "春秋", result.context.fetch("period")
  end

  test "specific one-character people are admitted by syntax and close contextual clustering" do
    store = HistoricalFixtureStore.new
    store.add_person("堯", year_start: -2300, year_end: -2200)
    store.add_person("舜", year_start: -2300, year_end: -2100)
    store.add_person("禹", year_start: -2200, year_end: -2100)

    result = CbdbAutoAnnotator.call(
      text: "堯曰：「咨！爾舜！」舜亦以命禹。",
      metadata: { "corpus_root" => "中國漢文", "period" => "先秦" },
      store: store
    )

    surfaces = result.items.select { |item| item.fetch("kind") == "person" }.map { |item| item.fetch("text") }
    assert_equal ["堯", "舜", "舜", "禹"], surfaces
  ensure
    store&.close
  end

  test "two different specific one-character names in close proximity can disambiguate each other" do
    store = HistoricalFixtureStore.new
    store.add_person("堯")
    store.add_person("舜")

    result = CbdbAutoAnnotator.call(
      text: "古稱堯與舜，二人相承。",
      metadata: { "corpus_root" => "中國漢文", "period" => "先秦" },
      store: store
    )

    surfaces = result.items.select { |item| item.fetch("kind") == "person" }.map { |item| item.fetch("text") }
    assert_equal ["堯", "舜"], surfaces
  ensure
    store&.close
  end

  test "an ambiguous one-character authority graph is not promoted merely because it precedes 曰" do
    store = HistoricalFixtureStore.new
    8.times { |index| store.add_person("子", id: "zi-#{index}") }

    result = CbdbAutoAnnotator.call(
      text: "子曰：學而時習之。",
      metadata: { "corpus_root" => "中國漢文", "period" => "先秦" },
      store: store
    )

    refute result.items.any? { |item| item.fetch("text") == "子" }
  ensure
    store&.close
  end

  test "an isolated one-character authority name without name-like context stays unannotated" do
    store = HistoricalFixtureStore.new
    store.add_person("堯")

    result = CbdbAutoAnnotator.call(
      text: "山高而堯遠，未足以定其所指。",
      metadata: { "corpus_root" => "中國漢文", "period" => "先秦" },
      store: store
    )

    refute result.items.any? { |item| item.fetch("text") == "堯" }
  ensure
    store&.close
  end
end
