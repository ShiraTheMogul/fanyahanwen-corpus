# frozen_string_literal: true

require_relative "../test_helper"

class EastAsianAuthorityUpdaterTest < ActiveSupport::TestCase
  test "Wikipedia era tables preserve Korean adoption as local use without resetting the Chinese era base" do
    updater = EastAsianAuthorityUpdater.new(cache_store: CorpusSearch::CacheStore.new(root: Rails.root.join("tmp", "test-era-parser")), logger: nil)
    html = <<~HTML
      <table class="wikitable"><tr>
        <td><a title="King Taejong of Joseon">King Taejong</a><br>太宗<br>(r. 1400–1418 CE)</td>
        <td>Yeongnak (Yongle)<br>永樂<br>영락</td>
        <td>1403–1418 CE</td><td>16 years</td>
        <td>Adopted the era name of the Ming dynasty of China.</td>
      </tr></table>
    HTML
    rows = updater.send(
      :parse_wikipedia_era_html,
      html,
      page_title: "Korean era name",
      country: "Korea",
      ruler_title_map: { "King Taejong of Joseon" => "QKING" },
      era_title_map: {}
    )
    row = rows.first
    assert_equal ["永樂"], row.fetch("han_names")
    assert row.fetch("adopted_from_foreign")
    assert_equal "China", row.fetch("origin_country")
    assert_nil row["start_year"]
    assert_equal 1403, row.fetch("local_use_start_year")
    assert_equal ["QKING"], row.fetch("ruler_qids")
  end

  test "Wikipedia era tables retain domestic Japanese era bases" do
    updater = EastAsianAuthorityUpdater.new(cache_store: CorpusSearch::CacheStore.new(root: Rails.root.join("tmp", "test-era-parser")), logger: nil)
    html = <<~HTML
      <table class="wikitable"><tr>
        <td><a title="Emperor Kōtoku">Emperor Kōtoku</a><br>孝徳天皇<br>(r. 645–654 CE)</td>
        <td><a title="Taika (era)">Taika</a><br>大化</td>
        <td>645–650 CE</td><td>5 years</td><td></td>
      </tr></table>
    HTML
    rows = updater.send(
      :parse_wikipedia_era_html,
      html,
      page_title: "Japanese era name",
      country: "Japan",
      ruler_title_map: { "Emperor Kōtoku" => "QKOTOKU" },
      era_title_map: { "Taika (era)" => "QTAIKA" }
    )
    row = rows.first
    assert_equal "QTAIKA", row.fetch("qid")
    assert_equal 645, row.fetch("start_year")
    assert_equal 650, row.fetch("end_year")
    refute row.fetch("adopted_from_foreign")
    assert_includes row.fetch("han_names"), "大化"
  end

  test "Korean Gaeguk preserves its retrospective 1392 epoch while recording 1894 local use" do
    updater = EastAsianAuthorityUpdater.new(cache_store: CorpusSearch::CacheStore.new(root: Rails.root.join("tmp", "test-era-parser")), logger: nil)
    html = <<~HTML
      <table class="wikitable"><tr>
        <td><a title="Gojong of Korea">King Gojong</a><br>高宗<br>(r. 1864–1897 CE)</td>
        <td>Gaeguk<br>開國<br>개국</td>
        <td>1894–1895 CE</td><td>2 years</td>
        <td>The 1st year of Gaeguk was officially taken to be 1392 CE; 1894 CE was therefore the 503rd year of Gaeguk.</td>
      </tr></table>
    HTML
    rows = updater.send(
      :parse_wikipedia_era_html,
      html,
      page_title: "Korean era name",
      country: "Korea",
      ruler_title_map: { "Gojong of Korea" => "QGOJONG" },
      era_title_map: {}
    )
    row = rows.first
    assert_equal ["開國"], row.fetch("han_names")
    refute row.fetch("adopted_from_foreign")
    assert_equal 1392, row.fetch("epoch_start_year")
    assert_equal 1894, row.fetch("local_use_start_year")
    assert_equal 1895, row.fetch("local_use_end_year")
  end

  test "Korean use of a Japanese era is represented as foreign local use" do
    updater = EastAsianAuthorityUpdater.new(cache_store: CorpusSearch::CacheStore.new(root: Rails.root.join("tmp", "test-era-parser")), logger: nil)
    html = <<~HTML
      <h3>Korea under Japanese rule</h3>
      <table class="wikitable"><tr>
        <td>Sohwa (Shōwa)<br>昭和</td>
        <td>1926–1945 CE</td><td>20 years</td>
        <td>Era name of the Emperor Shōwa.</td>
      </tr></table>
    HTML
    rows = updater.send(
      :parse_wikipedia_era_html,
      html,
      page_title: "Korean era name",
      country: "Korea",
      ruler_title_map: {},
      era_title_map: {}
    )
    row = rows.first
    assert row.fetch("adopted_from_foreign")
    assert_equal "Japan", row.fetch("origin_country")
    assert_nil row["start_year"]
    assert_equal 1926, row.fetch("local_use_start_year")
    assert_equal 1945, row.fetch("local_use_end_year")
  end

  test "a Korean emperor remark is not mistaken for Japanese adoption outside the Japanese-rule section" do
    updater = EastAsianAuthorityUpdater.new(cache_store: CorpusSearch::CacheStore.new(root: Rails.root.join("tmp", "test-era-parser")), logger: nil)
    assert_equal "Korea", updater.send(:foreign_era_origin, "Korea", "Era name of Emperor Gojong.", section_labels: ["Korean Empire"])
    assert_equal "Japan", updater.send(:foreign_era_origin, "Korea", "Era name of Emperor Shōwa.", section_labels: ["Korea under Japanese rule"])
  end


  test "foreign Wikidata era authorities are not relabelled as domestic merely because a local list links them" do
    updater = EastAsianAuthorityUpdater.new(cache_store: CorpusSearch::CacheStore.new(root: Rails.root.join("tmp", "test-era-parser")), logger: nil)
    assert updater.send(:foreign_era_entity?, "Korea", "Japanese era name", ["Empire of Japan"])
    assert updater.send(:foreign_era_entity?, "Korea", "Chinese era name", ["Ming dynasty"])
    refute updater.send(:foreign_era_entity?, "Korea", "Korean era name", ["Korean Empire"])
  end


  test "Korean Dangun calendar captures a BCE epoch" do
    updater = EastAsianAuthorityUpdater.new(cache_store: CorpusSearch::CacheStore.new(root: Rails.root.join("tmp", "test-era-parser")), logger: nil)
    html = <<~HTML
      <table class="wikitable"><tr>
        <td>Dangun-giwon<br>檀君紀元<br>단군기원</td>
        <td>1948–1961 CE</td><td>13 years</td>
        <td>Years were counted from the foundation of Gojoseon in 2333 BC (regarded as year one), hence these Dangi (단기; 檀紀) years were used.</td>
      </tr></table>
    HTML
    rows = updater.send(
      :parse_wikipedia_era_html,
      html,
      page_title: "Korean era name",
      country: "Korea",
      ruler_title_map: {},
      era_title_map: {}
    )
    row = rows.first
    assert_includes row.fetch("han_names"), "檀君紀元"
    assert_includes row.fetch("han_names"), "檀紀"
    assert_equal(-2333, row.fetch("epoch_start_year"))
    assert_equal 1948, row.fetch("local_use_start_year")
  end

  test "Korean Western-calendar designation keeps Common Era year numbering" do
    updater = EastAsianAuthorityUpdater.new(cache_store: CorpusSearch::CacheStore.new(root: Rails.root.join("tmp", "test-era-parser")), logger: nil)
    html = <<~HTML
      <table class="wikitable"><tr>
        <td>Seoryeokgiwon<br>西曆紀元</td>
        <td>1962–present</td><td>Current era</td>
        <td>"Age of Seoryeok [Western Calendar]", i.e. "Common Era"</td>
      </tr></table>
    HTML
    rows = updater.send(
      :parse_wikipedia_era_html,
      html,
      page_title: "Korean era name",
      country: "Korea",
      ruler_title_map: {},
      era_title_map: {}
    )
    row = rows.first
    assert_equal ["西曆紀元"], row.fetch("han_names")
    assert_equal 1, row.fetch("epoch_start_year")
    assert_equal 1962, row.fetch("local_use_start_year")
  end

  test "Vietnamese era-table alternatives and dynasty headings become authority aliases and context" do
    updater = EastAsianAuthorityUpdater.new(cache_store: CorpusSearch::CacheStore.new(root: Rails.root.join("tmp", "test-era-parser")), logger: nil)
    html = <<~HTML
      <h3>Lý dynasty</h3>
      <table class="wikitable">
        <tr><th>Era name</th><th>Period of use</th><th>Length of use</th><th>Remark</th></tr>
        <tr>
          <td><a title="Lý Thần Tông">Lý Thần Tông</a><br>李神宗<br>(r. 1127–1138 CE)</td>
          <td>Thiên Thuận<br>天順</td><td>1128–1132 CE</td><td>5 years</td><td>Or Đại Thuận (大順).</td>
        </tr>
      </table>
    HTML
    rows = updater.send(
      :parse_wikipedia_era_html, html, page_title: "Vietnamese era name", country: "Vietnam",
      ruler_title_map: { "Lý Thần Tông" => "QLY" }, era_title_map: {}
    )
    row = rows.first
    assert_includes row.fetch("han_names"), "天順"
    assert_includes row.fetch("han_names"), "大順"
    assert_includes row.fetch("polities"), "Lý dynasty"
  end

  test "Wikidata kana names are retained as ruler readings" do
    updater = EastAsianAuthorityUpdater.new(
      cache_store: CorpusSearch::CacheStore.new(root: Rails.root.join("tmp", "test-kana-reading")),
      logger: nil
    )
    entity = {
      "labels" => { "ja" => { "value" => "桓武天皇" }, "en" => { "value" => "Emperor Kanmu" } },
      "aliases" => {},
      "claims" => {
        "P1814" => [{ "mainsnak" => { "datavalue" => { "value" => "かんむてんのう" } } }]
      }
    }

    readings = updater.send(:reading_names, entity)
    assert_includes readings, "かんむてんのう"
  end

  test "same Han era name in overlapping incompatible polities remains separate" do
    updater = EastAsianAuthorityUpdater.new(
      cache_store: CorpusSearch::CacheStore.new(root: Rails.root.join("tmp", "test-era-collision")),
      logger: nil
    )
    eras = [{
      "qid" => "WP-Korea-a",
      "source" => "wikipedia_era_list",
      "country" => "Korea",
      "origin_country" => "Korea",
      "han_names" => ["建元"],
      "start_year" => 500,
      "end_year" => 510,
      "local_use_start_year" => 500,
      "local_use_end_year" => 510,
      "polities" => ["State A"],
      "ruler_qids" => [],
      "provenance" => []
    }]
    incoming = [{
      "qid" => "WP-Korea-b",
      "source" => "wikipedia_era_list",
      "country" => "Korea",
      "origin_country" => "Korea",
      "han_names" => ["建元"],
      "start_year" => 505,
      "end_year" => 515,
      "local_use_start_year" => 505,
      "local_use_end_year" => 515,
      "polities" => ["State B"],
      "ruler_qids" => [],
      "provenance" => []
    }]

    updater.send(:merge_era_list_rows!, eras, incoming)
    assert_equal 2, eras.length
    assert_equal ["State A", "State B"], eras.flat_map { |era| era.fetch("polities") }.sort
  end

  test "ruler-list chronology warnings are retained instead of presenting legendary dates as secure" do
    updater = EastAsianAuthorityUpdater.new(cache_store: CorpusSearch::CacheStore.new(root: Rails.root.join("tmp", "test-ruler-confidence")), logger: nil)
    assert_equal "traditional_or_legendary", updater.send(:ruler_chronology_confidence, "Son of Emperor Jimmu. Presumed legendary.")
    assert_equal "traditional_or_legendary", updater.send(:ruler_chronology_confidence, "Historicity disputed; traditional dates are retained.")
    assert_nil updater.send(:ruler_chronology_confidence, "Reigned 645–654 CE.")
  end

  test "canonical ruler-list rows survive sparse Wikidata modelling" do
    updater = EastAsianAuthorityUpdater.new(cache_store: CorpusSearch::CacheStore.new(root: Rails.root.join("tmp", "test-ruler-fallback")), logger: nil)
    rulers = []
    updater.send(
      :enrich_rulers_from_ruler_list!,
      rulers,
      {
        "QLEGEND" => {
          "qid" => "QLEGEND",
          "han_names" => ["神武天皇", "彦火火出見"],
          "polities" => ["Ancient Japan"],
          "reign_start_year" => -660,
          "reign_end_year" => -585,
          "chronology_confidence" => "traditional_or_legendary",
          "chronology_note" => "Traditional chronology.",
          "provenance" => ["Wikipedia ruler list (CC BY-SA 4.0)"]
        }
      },
      country: "Japan"
    )
    assert_equal 1, rulers.length
    assert_equal "wikipedia_ruler_list", rulers.first.fetch("source")
    assert_includes rulers.first.fetch("han_names"), "彦火火出見"
    assert_equal(-660, rulers.first.fetch("reign_start_year"))
  end

  test "ruler tables still produce stable authorities when Wikidata enrichment is unavailable" do
    updater = EastAsianAuthorityUpdater.new(
      cache_store: CorpusSearch::CacheStore.new(root: Rails.root.join("tmp", "test-ruler-wikipedia-fallback")),
      logger: nil
    )
    html = <<~HTML
      <h3>Asuka period</h3>
      <table>
        <tr><th>Emperor</th><th>Personal name</th><th>Period of reign</th></tr>
        <tr>
          <td><a title="Emperor Kōtoku">孝徳天皇</a></td>
          <td>輕皇子</td>
          <td>645–654 CE</td>
        </tr>
      </table>
    HTML

    rows = updater.send(
      :parse_wikipedia_ruler_html,
      html,
      page_title: "List of emperors of Japan",
      ruler_title_map: {},
      country: "Japan"
    )
    assert_equal 1, rows.length
    id, row = rows.first
    assert_match(/\AWP-RULER-Japan-/, id)
    assert_includes row.fetch("han_names"), "孝徳天皇"
    assert_includes row.fetch("han_names"), "輕皇子"
    assert_equal 645, row.fetch("reign_start_year")
    assert_equal 654, row.fetch("reign_end_year")
  end

  test "Wikipedia article HTML is used when the MediaWiki parse API is unavailable" do
    updater = EastAsianAuthorityUpdater.new(
      cache_store: CorpusSearch::CacheStore.new(root: Rails.root.join("tmp", "test-wikipedia-html-fallback")),
      logger: nil
    )
    direct_html = "<html><body><table><tr><td>大化</td></tr></table></body></html>"

    updater.stub(:get_json, ->(*) { raise Net::ReadTimeout, "timed out" }) do
      updater.stub(:get_text, direct_html) do
        assert_equal direct_html, updater.send(:wikipedia_page_html, "Japanese era name")
      end
    end
  end

  test "JSON helper accepts Ruby 3 keyword query parameters as well as a positional params hash" do
    updater = EastAsianAuthorityUpdater.new(
      cache_store: CorpusSearch::CacheStore.new(root: Rails.root.join("tmp", "test-api-keywords")),
      logger: nil
    )
    captured = []
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, %({"query":{"pages":[]}}))

    fake_request = lambda do |uri, limit:, accept:|
      captured << [uri, limit, accept]
      response
    end

    updater.stub(:request, fake_request) do
      payload = updater.send(
        :get_json,
        "https://example.test/w/api.php",
        action: "query",
        prop: "pageprops",
        format: "json"
      )
      assert_equal [], payload.dig("query", "pages")

      updater.send(
        :get_json,
        "https://example.test/w/api.php",
        { action: "parse", page: "Japanese era name" }
      )
    end

    first_query = URI.decode_www_form(captured.fetch(0).fetch(0).query).to_h
    assert_equal "query", first_query.fetch("action")
    assert_equal "pageprops", first_query.fetch("prop")
    assert_equal "json", first_query.fetch("format")

    second_query = URI.decode_www_form(captured.fetch(1).fetch(0).query).to_h
    assert_equal "parse", second_query.fetch("action")
    assert_equal "Japanese era name", second_query.fetch("page")
  end

  test "Wikipedia canonical table rows bound Wikidata discovery scope" do
    updater = EastAsianAuthorityUpdater.new(
      cache_store: CorpusSearch::CacheStore.new(root: Rails.root.join("tmp", "test-canonical-scope")),
      logger: nil
    )
    records = [
      { "qid" => "QCANONICAL", "country" => "Korea" },
      { "qid" => "QFOREIGN-LINK", "country" => "Korea" },
      { "qid" => "QFOOTNOTE-KING", "country" => "Korea" }
    ]

    discarded = updater.send(:retain_canonical_records!, records, ["QCANONICAL"])

    assert_equal 2, discarded
    assert_equal ["QCANONICAL"], records.map { |row| row.fetch("qid") }
  end


  test "era ruler inference drops links to rulers outside canonical discovery scope" do
    updater = EastAsianAuthorityUpdater.new(
      cache_store: CorpusSearch::CacheStore.new(root: Rails.root.join("tmp", "test-era-ruler-scope")),
      logger: nil
    )
    rulers = [{
      "qid" => "QCANONICAL", "country" => "Japan",
      "reign_start_year" => 645, "reign_end_year" => 654
    }]
    eras = [{
      "qid" => "QERA", "country" => "Japan", "start_year" => 645, "end_year" => 650,
      "ruler_qids" => ["QCANONICAL", "QFOREIGN-LINK"]
    }]

    updater.send(:infer_era_rulers!, eras, rulers)

    assert_equal ["QCANONICAL"], eras.first.fetch("ruler_qids")
  end


end
