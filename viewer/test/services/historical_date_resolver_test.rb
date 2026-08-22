# frozen_string_literal: true

require_relative "../test_helper"
require "digest"
require "tmpdir"

class HistoricalDateResolverTest < ActiveSupport::TestCase
  test "normalizes common absolute date labels without requiring an authority cache" do
    unavailable_store = Object.new
    unavailable_store.define_singleton_method(:available?) { false }
    resolver = HistoricalDateResolver.new(store: unavailable_store)

    cases = {
      "1940年" => [1940, 1940, "date_label_absolute", "explicit_label"],
      "1927年4月9日" => [1927, 1927, "date_label_absolute", "explicit_label"],
      "481 BC" => [-481, -481, "date_label_absolute", "explicit_label"],
      "公元前481年" => [-481, -481, "date_label_absolute", "explicit_label"],
      "1856–1857" => [1856, 1857, "date_label_absolute", "explicit_label"],
      "1565頃" => [1565, 1565, "date_label_absolute", "approximate_label"],
      "2026-06-03T15:05:56Z" => [2026, 2026, "date_label_iso8601", "explicit_label"]
    }

    cases.each do |label, expected|
      resolution = resolver.resolve(metadata: { "corpus_root" => "中國漢文", "date_label" => label })
      assert resolution, "expected #{label.inspect} to resolve"
      assert_equal expected[0], resolution.year_start, label
      assert_equal expected[1], resolution.year_end, label
      assert_equal expected[2], resolution.source, label
      assert_equal expected[3], resolution.confidence, label
      assert_nil resolution.authority_kind, label
    end

    assert_nil resolver.resolve(metadata: { "corpus_root" => "中國漢文", "date_label" => "不詳" })
  end

  test "normalizes Han-digit Gregorian years in date labels" do
    unavailable_store = Object.new
    unavailable_store.define_singleton_method(:available?) { false }
    resolution = HistoricalDateResolver.new(store: unavailable_store).resolve(
      metadata: { "corpus_root" => "中國漢文", "date_label" => "一九七一年" }
    )
    assert_equal 1971, resolution.year_start
    assert_equal 1971, resolution.year_end
  end

  test "resolves Japanese era and ruler regnal years" do
    Dir.mktmpdir do |directory|
      cache_store, historical_path = build_historical_cache(directory)
      store = HistoricalAuthorityStore.new(
        cbdb_path: nil,
        cbdb_release: {},
        lookup_path: nil,
        historical_path: historical_path,
        cache_store: cache_store,
        logger: nil
      )
      resolver = HistoricalDateResolver.new(store: store)

      era = resolver.resolve(metadata: { "corpus_root" => "日本漢文", "date_label" => "大化三年" })
      assert_equal 647, era.year_start
      assert_equal "era", era.authority_kind
      assert_equal "Japan", era.country

      regnal = resolver.resolve(metadata: { "corpus_root" => "日本漢文", "date_label" => "孝徳天皇三年" })
      assert_equal 647, regnal.year_start
      assert_equal "ruler", regnal.authority_kind
    end
  end

  test "uses dynasty context to disambiguate reused Chinese era names" do
    Dir.mktmpdir do |directory|
      cache_store, historical_path = build_historical_cache(directory)
      cbdb = Pathname(directory).join("cbdb.sqlite3")
      build_cbdb(cbdb)
      store = HistoricalAuthorityStore.new(
        cbdb_path: cbdb,
        cbdb_release: { "sha256" => Digest::SHA256.file(cbdb).hexdigest },
        lookup_path: nil,
        historical_path: historical_path,
        cache_store: cache_store,
        logger: nil
      )

      resolution = HistoricalDateResolver.new(store: store).resolve(
        metadata: { "corpus_root" => "中國漢文", "period" => "唐", "date_label" => "元和三年" }
      )
      assert_equal 808, resolution.year_start
      assert_equal "元和", resolution.authority_name
    end
  end

  test "Korean local-use evidence supports an adopted Chinese era without resetting year one" do
    Dir.mktmpdir do |directory|
      cache_store, historical_path = build_historical_cache(directory)
      cbdb = Pathname(directory).join("cbdb.sqlite3")
      build_cbdb(cbdb)
      store = HistoricalAuthorityStore.new(
        cbdb_path: cbdb,
        cbdb_release: { "sha256" => Digest::SHA256.file(cbdb).hexdigest },
        lookup_path: nil,
        historical_path: historical_path,
        cache_store: cache_store,
        logger: nil
      )

      resolution = HistoricalDateResolver.new(store: store).resolve(
        metadata: { "corpus_root" => "朝鮮漢文", "period" => "朝鮮王朝", "date_label" => "永樂十年" }
      )
      assert_equal 1412, resolution.year_start
      assert_equal "cbdb", resolution.source
    end
  end


  test "Korean Gaeguk uses its retrospective epoch rather than its nineteenth-century adoption year" do
    Dir.mktmpdir do |directory|
      cache_store, historical_path = build_historical_cache(directory)
      store = HistoricalAuthorityStore.new(
        cbdb_path: nil,
        cbdb_release: {},
        lookup_path: nil,
        historical_path: historical_path,
        cache_store: cache_store,
        logger: nil
      )

      resolution = HistoricalDateResolver.new(store: store).resolve(
        metadata: { "corpus_root" => "朝鮮漢文", "period" => "朝鮮王朝", "date_label" => "開國五百三年" }
      )
      assert_equal 1894, resolution.year_start
      assert_equal "開國", resolution.authority_name
    end
  end

  test "Korean local-use evidence can support a Japanese era authority" do
    Dir.mktmpdir do |directory|
      cache_store, historical_path = build_historical_cache(directory)
      store = HistoricalAuthorityStore.new(
        cbdb_path: nil,
        cbdb_release: {},
        lookup_path: nil,
        historical_path: historical_path,
        cache_store: cache_store,
        logger: nil
      )

      resolution = HistoricalDateResolver.new(store: store).resolve(
        metadata: { "corpus_root" => "朝鮮漢文", "period" => "日治時期", "date_label" => "昭和十年" }
      )
      assert_equal 1935, resolution.year_start
      assert_equal "Japan", resolution.country
    end
  end

  test "era-year parser accepts shorthand tens and whitespace" do
    Dir.mktmpdir do |directory|
      cache_store, historical_path = build_historical_cache(directory)
      store = HistoricalAuthorityStore.new(
        cbdb_path: nil,
        cbdb_release: {},
        lookup_path: nil,
        historical_path: historical_path,
        cache_store: cache_store,
        logger: nil
      )

      resolution = HistoricalDateResolver.new(store: store).resolve(
        metadata: { "corpus_root" => "日本漢文", "date_label" => "昭和 卅年" }
      )
      assert_equal 1955, resolution.year_start
    end
  end


  test "BCE calendar epochs skip year zero when resolving into CE" do
    Dir.mktmpdir do |directory|
      cache_store, historical_path = build_historical_cache(directory)
      store = HistoricalAuthorityStore.new(
        cbdb_path: nil,
        cbdb_release: {},
        lookup_path: nil,
        historical_path: historical_path,
        cache_store: cache_store,
        logger: nil
      )

      resolution = HistoricalDateResolver.new(store: store).resolve(
        metadata: { "corpus_root" => "朝鮮漢文", "date_label" => "檀君紀元四千二百八十一年" }
      )
      assert_equal 1948, resolution.year_start
    end
  end

  test "Korean Common Era designation uses CE year numbers rather than adoption-year offsets" do
    Dir.mktmpdir do |directory|
      cache_store, historical_path = build_historical_cache(directory)
      store = HistoricalAuthorityStore.new(
        cbdb_path: nil,
        cbdb_release: {},
        lookup_path: nil,
        historical_path: historical_path,
        cache_store: cache_store,
        logger: nil
      )

      resolution = HistoricalDateResolver.new(store: store).resolve(
        metadata: { "corpus_root" => "朝鮮漢文", "date_label" => "西曆紀元一九六二年" }
      )
      assert_equal 1962, resolution.year_start
    end
  end

  test "date parser evaluates separate year expressions independently" do
    Dir.mktmpdir do |directory|
      cache_store, historical_path = build_historical_cache(directory)
      store = HistoricalAuthorityStore.new(
        cbdb_path: nil, cbdb_release: {}, lookup_path: nil, historical_path: historical_path,
        cache_store: cache_store, logger: nil
      )
      resolver = HistoricalDateResolver.new(store: store)
      expressions = resolver.send(:expressions, "大化三年、昭和十年")
      assert_equal [3, 10], expressions.map { |row| row.fetch("year_number") }
      assert_equal ["大化", "、昭和"], expressions.map { |row| row.fetch("prefix") }
    end
  end

  test "traditional Japanese ruler chronology resolves but is explicitly marked non-secure" do
    Dir.mktmpdir do |directory|
      cache_store, historical_path = build_historical_cache(directory)
      store = HistoricalAuthorityStore.new(
        cbdb_path: nil, cbdb_release: {}, lookup_path: nil, historical_path: historical_path,
        cache_store: cache_store, logger: nil
      )

      resolution = HistoricalDateResolver.new(store: store).resolve(
        metadata: { "corpus_root" => "日本漢文", "date_label" => "神武天皇三年" }
      )
      assert_equal(-658, resolution.year_start)
      assert_equal "traditional", resolution.confidence
      assert_equal "traditional_or_legendary", resolution.candidates.first.fetch("chronology_confidence")
    end
  end

  test "resolves project-curated Daxi Dashun and Dashun Yongchang continuations" do
    Dir.mktmpdir do |directory|
      cache_store, historical_path = build_historical_cache(directory)
      store = HistoricalAuthorityStore.new(
        cbdb_path: nil, cbdb_release: {}, lookup_path: nil, historical_path: historical_path,
        cache_store: cache_store, logger: nil
      )
      resolver = HistoricalDateResolver.new(store: store)

      daxi = resolver.resolve(
        metadata: { "corpus_root" => "中國漢文", "polity" => "大西", "date_label" => "大順三年" }
      )
      assert_equal 1646, daxi.year_start
      assert_equal "大順", daxi.authority_name

      remnant = resolver.resolve(
        metadata: { "corpus_root" => "中國漢文", "polity" => "大順餘部", "date_label" => "永昌十年" }
      )
      assert_equal 1653, remnant.year_start
      assert_equal "永昌", remnant.authority_name
    end
  end

  test "resolves Taiping state-name dating including altered sexagenary branch characters" do
    Dir.mktmpdir do |directory|
      cache_store, historical_path = build_historical_cache(directory)
      store = HistoricalAuthorityStore.new(
        cbdb_path: nil, cbdb_release: {}, lookup_path: nil, historical_path: historical_path,
        cache_store: cache_store, logger: nil
      )
      resolver = HistoricalDateResolver.new(store: store)

      third = resolver.resolve(
        metadata: { "corpus_root" => "中國漢文", "polity" => "太平天國", "date_label" => "太平天國癸好三年" }
      )
      assert_equal 1853, third.year_start
      assert_equal "太平天國", third.authority_name

      first = resolver.resolve(
        metadata: { "corpus_root" => "中國漢文", "polity" => "太平天國", "date_label" => "太平天囯辛開元年" }
      )
      assert_equal 1851, first.year_start

      diagnostics = resolver.era_candidates_for(
        metadata: { "corpus_root" => "中國漢文", "polity" => "太平天國", "date_label" => "太平天國癸好三年" }
      )
      assert diagnostics.any? { |candidate| candidate.fetch("id") == "china-taiping-tianguo-main" && candidate.fetch("within_use") }
    end
  end

  test "does not treat Tian-de as a Taiping era alias" do
    Dir.mktmpdir do |directory|
      cache_store, historical_path = build_historical_cache(directory)
      store = HistoricalAuthorityStore.new(
        cbdb_path: nil, cbdb_release: {}, lookup_path: nil, historical_path: historical_path,
        cache_store: cache_store, logger: nil
      )

      resolution = HistoricalDateResolver.new(store: store).resolve(
        metadata: { "corpus_root" => "中國漢文", "polity" => "太平天國", "date_label" => "天德三年" }
      )
      assert_nil resolution
    end
  end

  private

  def build_historical_cache(directory)
    cache_store = CorpusSearch::CacheStore.new(root: Pathname(directory).join("cache"))
    snapshot = {
      "version" => EastAsianAuthorityUpdater::VERSION,
      "generated_at_utc" => Time.now.utc.iso8601,
      "rulers" => [{
        "qid" => "QTEST1", "source" => "wikidata_east_asia", "country" => "Japan",
        "label" => "孝徳天皇", "local_label" => "孝徳天皇", "han_names" => ["孝徳天皇"],
        "readings" => ["Emperor Kōtoku"], "reign_start_year" => 645, "reign_end_year" => 654,
        "positions" => ["Emperor of Japan"], "source_url" => "https://www.wikidata.org/wiki/QTEST1"
      }, {
        "qid" => "QJIMMU", "source" => "wikidata_east_asia", "country" => "Japan",
        "label" => "神武天皇", "local_label" => "神武天皇", "han_names" => ["神武天皇", "彦火火出見"],
        "readings" => ["Emperor Jimmu"], "reign_start_year" => -660, "reign_end_year" => -585,
        "chronology_confidence" => "traditional_or_legendary",
        "chronology_note" => "Wikipedia's ruler list explicitly flags this chronology as legendary, disputed, or traditional.",
        "positions" => ["Emperor of Japan"], "source_url" => "https://www.wikidata.org/wiki/QJIMMU"
      }],
      "eras" => [
        {
          "qid" => "QERA1", "source" => "wikidata_east_asia", "country" => "Japan", "origin_country" => "Japan",
          "label" => "大化", "han_names" => ["大化"], "readings" => ["Taika"], "start_year" => 645, "end_year" => 650,
          "local_use_start_year" => 645, "local_use_end_year" => 650, "adopted_from_foreign" => false,
          "ruler_qids" => ["QTEST1"], "source_url" => "https://www.wikidata.org/wiki/QERA1"
        },
        {
          "qid" => "WP-Korea-dangun", "source" => "wikipedia_era_list", "country" => "Korea", "origin_country" => "Korea",
          "label" => "Dangun-giwon", "han_names" => ["檀君紀元"], "readings" => ["Dangun-giwon"], "start_year" => 1948, "end_year" => 1961,
          "epoch_start_year" => -2333, "local_use_start_year" => 1948, "local_use_end_year" => 1961, "adopted_from_foreign" => false,
          "ruler_qids" => [], "source_url" => "https://en.wikipedia.org/wiki/Korean_era_name"
        },
        {
          "qid" => "WP-Korea-gaeguk", "source" => "wikipedia_era_list", "country" => "Korea", "origin_country" => "Korea",
          "label" => "Gaeguk", "han_names" => ["開國"], "readings" => ["Gaeguk"], "start_year" => 1894, "end_year" => 1895,
          "epoch_start_year" => 1392, "local_use_start_year" => 1894, "local_use_end_year" => 1895, "adopted_from_foreign" => false,
          "ruler_qids" => [], "source_url" => "https://en.wikipedia.org/wiki/Korean_era_name"
        },
        {
          "qid" => "QSHOWA", "source" => "wikidata_east_asia", "country" => "Japan", "origin_country" => "Japan",
          "label" => "昭和", "han_names" => ["昭和"], "readings" => ["Shōwa"], "start_year" => 1926, "end_year" => 1989,
          "local_use_start_year" => 1926, "local_use_end_year" => 1989, "adopted_from_foreign" => false,
          "ruler_qids" => [], "source_url" => "https://www.wikidata.org/wiki/QSHOWA"
        },
        {
          "qid" => "WP-Korea-showa", "source" => "wikipedia_era_list", "country" => "Korea", "origin_country" => "Japan",
          "label" => "Shōwa", "han_names" => ["昭和"], "readings" => ["Shōwa"], "start_year" => nil, "end_year" => nil,
          "local_use_start_year" => 1926, "local_use_end_year" => 1945, "adopted_from_foreign" => true,
          "ruler_qids" => [], "source_url" => "https://en.wikipedia.org/wiki/Korean_era_name"
        },
        {
          "qid" => "WP-Korea-seoryeok", "source" => "wikipedia_era_list", "country" => "Korea", "origin_country" => "Korea",
          "label" => "Seoryeokgiwon", "han_names" => ["西曆紀元"], "readings" => ["Seoryeokgiwon"], "start_year" => 1962, "end_year" => Time.now.utc.year,
          "epoch_start_year" => 1, "local_use_start_year" => 1962, "local_use_end_year" => Time.now.utc.year, "adopted_from_foreign" => false,
          "ruler_qids" => [], "source_url" => "https://en.wikipedia.org/wiki/Korean_era_name"
        },
        {
          "qid" => "WP-Korea-test", "source" => "wikipedia_era_list", "country" => "Korea", "origin_country" => "China",
          "label" => "Yeongnak", "han_names" => ["永樂"], "readings" => ["Yeongnak"], "start_year" => nil, "end_year" => nil,
          "local_use_start_year" => 1403, "local_use_end_year" => 1418, "adopted_from_foreign" => true,
          "ruler_qids" => [], "source_url" => "https://en.wikipedia.org/wiki/Korean_era_name"
        }
      ]
    }
    cache_store.write_json(EastAsianAuthorityUpdater::SNAPSHOT_PATH, snapshot)
    result = HistoricalAuthorityIndex.build_if_needed!(cache_store: cache_store, snapshot: snapshot, logger: nil)
    [cache_store, result.path]
  end

  def build_cbdb(path)
    db = SQLite3::Database.new(path.to_s)
    db.execute_batch <<~SQL
      CREATE TABLE BIOG_MAIN (c_personid INTEGER PRIMARY KEY, c_name_chn TEXT);
      CREATE TABLE NIAN_HAO (
        c_nianhao_id INTEGER PRIMARY KEY,
        c_dynasty_chn TEXT,
        c_nianhao_chn TEXT,
        c_firstyear INTEGER,
        c_lastyear INTEGER
      );
      INSERT INTO NIAN_HAO VALUES (1, '東漢', '元和', 84, 87);
      INSERT INTO NIAN_HAO VALUES (2, '唐', '元和', 806, 820);
      INSERT INTO NIAN_HAO VALUES (3, '明', '永樂', 1403, 1424);
    SQL
  ensure
    db&.close
  end
end
