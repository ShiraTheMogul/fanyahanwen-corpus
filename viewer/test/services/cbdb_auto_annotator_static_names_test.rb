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
        CREATE TABLE historical.clans (
          source TEXT NOT NULL,
          entity_id TEXT NOT NULL,
          country TEXT,
          label TEXT,
          period_labels TEXT,
          chronology_confidence TEXT,
          source_url TEXT,
          source_citations TEXT,
          PRIMARY KEY (source, entity_id)
        );
        CREATE TABLE historical.clan_names (
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
        CREATE TABLE historical.clan_members (
          clan_source TEXT NOT NULL,
          clan_id TEXT NOT NULL,
          person_source TEXT NOT NULL,
          person_id TEXT NOT NULL,
          PRIMARY KEY (clan_source, clan_id, person_source, person_id)
        );
      SQL
    end

    def add_person(name, id: name, year_start: nil, year_end: nil, source: "fixture", chronology_confidence: nil, aliases: [])
      @db.execute(
        "INSERT INTO historical.people (source, entity_id, country, label, year_start, year_end, roles, chronology_confidence) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        [source, id, "China", name, year_start, year_end, "ruler", chronology_confidence]
      )
      [name, *aliases].uniq.each_with_index do |authority_name, index|
        length = authority_name.each_char.count
        prefix = authority_name.each_char.take([2, length].min).join
        @db.execute(
          "INSERT INTO historical.names (prefix, name_length, name_chn, source, entity_id, primary_name, explicit_name, derivation) VALUES (?, ?, ?, ?, ?, ?, 1, 'fixture_explicit')",
          [prefix, length, authority_name, source, id, index.zero? ? 1 : 0]
        )
      end
    end

    def add_clan(name, id: "clan:#{name}", source: CbdbAutoAnnotatorStaticNames::HIGH_ANTIQUITY_AUTHORITY_SOURCE,
      chronology_confidence: CbdbAutoAnnotatorStaticNames::HIGH_ANTIQUITY_CHRONOLOGY_CONFIDENCE, period_labels: "五帝傳說")
      @db.execute(
        "INSERT INTO historical.clans (source, entity_id, country, label, period_labels, chronology_confidence) VALUES (?, ?, ?, ?, ?, ?)",
        [source, id, "China", name, period_labels, chronology_confidence]
      )
      length = name.each_char.count
      prefix = name.each_char.take([2, length].min).join
      @db.execute(
        "INSERT INTO historical.clan_names (prefix, name_length, name_chn, source, entity_id, primary_name, explicit_name, derivation) VALUES (?, ?, ?, ?, ?, 1, 1, 'fixture_explicit')",
        [prefix, length, name, source, id]
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

  test "curated high-antiquity people need no invented numeric life dates" do
    store = HistoricalFixtureStore.new
    source = CbdbAutoAnnotatorStaticNames::HIGH_ANTIQUITY_AUTHORITY_SOURCE
    confidence = CbdbAutoAnnotatorStaticNames::HIGH_ANTIQUITY_CHRONOLOGY_CONFIDENCE
    store.add_person("堯", source: source, chronology_confidence: confidence)
    store.add_person("舜", source: source, chronology_confidence: confidence, aliases: ["重華"])
    store.add_person("禹", source: source, chronology_confidence: confidence)
    store.add_person("帝嚳", source: source, chronology_confidence: confidence, aliases: ["嚳", "高辛"])

    result = CbdbAutoAnnotator.call(
      text: "堯曰。舜曰。禹曰。嚳曰。重華曰。高辛曰。",
      metadata: { "corpus_root" => "中國漢文", "period" => "先秦" },
      store: store
    )

    surfaces = result.items.select { |item| item.fetch("kind") == "person" }.map { |item| item.fetch("text") }
    assert_equal ["堯", "舜", "禹", "嚳", "重華", "高辛"], surfaces
    result.items.each do |item|
      item.fetch("candidates").each do |candidate|
        next unless candidate.fetch("authority_source") == source
        assert_nil candidate["year_start"]
        assert_nil candidate["year_end"]
        assert_nil candidate["representative_year"]
      end
    end
  ensure
    store&.close
  end

  test "curated high-antiquity candidate survives unrelated one-character homograph noise" do
    store = HistoricalFixtureStore.new
    source = CbdbAutoAnnotatorStaticNames::HIGH_ANTIQUITY_AUTHORITY_SOURCE
    confidence = CbdbAutoAnnotatorStaticNames::HIGH_ANTIQUITY_CHRONOLOGY_CONFIDENCE
    store.add_person("益", id: "boyi", source: source, chronology_confidence: confidence)
    8.times do |index|
      store.add_person("益", id: "later-#{index}", source: "later-#{index}", year_start: 1400 + index, year_end: 1450 + index)
    end

    result = CbdbAutoAnnotator.call(
      text: "益曰：予思日孜孜。",
      metadata: { "corpus_root" => "中國漢文", "period" => "先秦" },
      store: store
    )

    item = result.items.find { |row| row.fetch("text") == "益" }
    assert item
    assert_equal ["boyi"], item.fetch("candidates").map { |candidate| candidate.fetch("id") }
  ensure
    store&.close
  end

  test "explicit high-antiquity aliases before speech verbs remain usable" do
    store = HistoricalFixtureStore.new
    source = CbdbAutoAnnotatorStaticNames::HIGH_ANTIQUITY_AUTHORITY_SOURCE
    confidence = CbdbAutoAnnotatorStaticNames::HIGH_ANTIQUITY_CHRONOLOGY_CONFIDENCE
    store.add_person("皋陶", source: source, chronology_confidence: confidence, aliases: ["咎陶", "皋繇"])

    result = CbdbAutoAnnotator.call(
      text: "咎陶曰。皋繇問。",
      metadata: { "corpus_root" => "中國漢文", "period" => "先秦" },
      store: store
    )

    assert_equal ["咎陶", "皋繇"], result.items.map { |item| item.fetch("text") }
  ensure
    store&.close
  end

  test "two different dated one-character names in close proximity can disambiguate each other" do
    store = HistoricalFixtureStore.new
    store.add_person("堯", year_start: -2300, year_end: -2200)
    store.add_person("舜", year_start: -2300, year_end: -2100)

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

  test "an ambiguous dated one-character authority graph is not promoted merely because it precedes 曰" do
    store = HistoricalFixtureStore.new
    8.times { |index| store.add_person("子", id: "zi-#{index}", year_start: -700, year_end: -400) }

    result = CbdbAutoAnnotator.call(
      text: "子曰：學而時習之。",
      metadata: { "corpus_root" => "中國漢文", "period" => "先秦" },
      store: store
    )

    refute result.items.any? { |item| item.fetch("text") == "子" }
  ensure
    store&.close
  end

  test "explicit high-antiquity 氏 records are annotated as clans" do
    store = HistoricalFixtureStore.new
    store.add_clan("有虞氏", period_labels: "五帝傳說; 有虞世系")

    result = CbdbAutoAnnotator.call(
      text: "有虞氏始見典制。",
      metadata: { "corpus_root" => "中國漢文", "period" => "先秦" },
      store: store
    )

    item = result.items.find { |row| row.fetch("text") == "有虞氏" }
    assert item
    assert_equal "clan", item.fetch("kind")
    assert_equal "有虞氏", item.fetch("candidates").first.fetch("label")
  ensure
    store&.close
  end

  test "氏 syntax makes an explicit clan beat a homographic person record" do
    store = HistoricalFixtureStore.new
    source = CbdbAutoAnnotatorStaticNames::HIGH_ANTIQUITY_AUTHORITY_SOURCE
    confidence = CbdbAutoAnnotatorStaticNames::HIGH_ANTIQUITY_CHRONOLOGY_CONFIDENCE
    store.add_person("燧人氏", source: source, chronology_confidence: confidence)
    store.add_clan("燧人氏", source: source, chronology_confidence: confidence, period_labels: "三皇傳說")

    result = CbdbAutoAnnotator.call(
      text: "燧人氏曰。",
      metadata: { "corpus_root" => "中國漢文", "period" => "先秦" },
      store: store
    )

    item = result.items.find { |row| row.fetch("text") == "燧人氏" }
    assert item
    assert_equal "clan", item.fetch("kind")
  ensure
    store&.close
  end

  test "氏 does not create a clan without a curated clan authority record" do
    store = HistoricalFixtureStore.new
    store.add_person("孔氏", year_start: -600, year_end: -400)

    result = CbdbAutoAnnotator.call(
      text: "孔氏曰。",
      metadata: { "corpus_root" => "中國漢文", "period" => "春秋" },
      store: store
    )

    item = result.items.find { |row| row.fetch("text") == "孔氏" }
    assert item
    assert_equal "person", item.fetch("kind")
    refute result.items.any? { |row| row.fetch("kind") == "clan" }
  ensure
    store&.close
  end

  test "an isolated dated one-character authority name without name-like context stays unannotated" do
    store = HistoricalFixtureStore.new
    store.add_person("堯", year_start: -2300, year_end: -2200)

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
