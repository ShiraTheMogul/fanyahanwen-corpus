# frozen_string_literal: true

require_relative "../test_helper"
require "digest"
require "roo"
require "sqlite3"
require "tmpdir"

class HistoricalAuthorityHighAntiquityTest < ActiveSupport::TestCase
  test "editable high-antiquity workbook carries people and source tables" do
    path = Rails.root.join("data", "three_sovereigns_five_emperors.xlsx")
    assert path.file?

    workbook = Roo::Excelx.new(path.to_s)
    assert_includes workbook.sheets, "People"
    assert_includes workbook.sheets, "Sources"

    headers = workbook.sheet("People").row(1).map(&:to_s)
    %w[person_id name_han aliases chronology_confidence source_ids source_citations clans].each do |header|
      assert_includes headers, header
    end

    source_headers = workbook.sheet("Sources").row(1).map(&:to_s)
    %w[source_id citation url].each { |header| assert_includes source_headers, header }
  ensure
    workbook&.close rescue nil
  end

  test "curated high-antiquity spreadsheet is indexed with explicit aliases and provenance" do
    Dir.mktmpdir do |directory|
      cache_store = CorpusSearch::CacheStore.new(root: Pathname(directory).join("cache"))
      snapshot = {
        "version" => EastAsianAuthorityUpdater::VERSION,
        "generated_at_utc" => Time.now.utc.iso8601,
        "rulers" => [],
        "eras" => []
      }
      cache_store.write_json(EastAsianAuthorityUpdater::SNAPSHOT_PATH, snapshot)

      result = HistoricalAuthorityIndex.build_if_needed!(cache_store: cache_store, snapshot: snapshot, logger: nil)
      assert result.available?

      db = SQLite3::Database.new(result.path, readonly: true)
      db.results_as_hash = true
      source = HistoricalAuthorityIndexStaticNames::HIGH_ANTIQUITY_SOURCE

      assert_operator db.get_first_value("SELECT COUNT(*) FROM people WHERE source = ?", [source]).to_i, :>=, 30

      shun = db.get_first_row("SELECT * FROM people WHERE source = ? AND entity_id = 'shun'", [source])
      assert shun
      assert_equal "舜", shun.fetch("label")
      assert_equal "traditional_high_antiquity", shun.fetch("chronology_confidence")
      assert_nil shun["year_start"]
      assert_nil shun["year_end"]
      assert_match(/Sima, Qian 司馬遷/, shun.fetch("source_citations"))
      assert_match(%r{https://ctext\.org/shiji/wu-di-ben-ji/zh}, shun.fetch("source_url"))

      names = db.execute(
        "SELECT name_chn FROM names WHERE source = ? AND entity_id = 'shun' AND explicit_name = 1 ORDER BY name_length, name_chn",
        [source]
      ).map { |row| row.fetch("name_chn") }
      assert_includes names, "舜"
      assert_includes names, "重華"
      assert_includes names, "虞舜"

      gaoyao_names = db.execute(
        "SELECT name_chn FROM names WHERE source = ? AND entity_id = 'gaoyao' AND explicit_name = 1",
        [source]
      ).map { |row| row.fetch("name_chn") }
      %w[皋陶 臯陶 咎陶 皋繇 咎繇].each { |name| assert_includes gaoyao_names, name }

      guiman = db.get_first_row("SELECT * FROM people WHERE source = ? AND entity_id = 'guiman'", [source])
      assert_equal "西周", guiman.fetch("polity")
      assert_match(/陳杞世家/, guiman.fetch("source_citations"))

      clan = db.get_first_row("SELECT * FROM clans WHERE source = ? AND entity_id = ?", [source, "clan:有虞氏"])
      assert clan
      assert_equal "有虞氏", clan.fetch("label")
      assert_match(/五帝傳說|有虞世系/, clan.fetch("period_labels"))
      assert_match(/Sima, Qian 司馬遷/, clan.fetch("source_citations"))

      clan_names = db.execute(
        "SELECT name_chn FROM clan_names WHERE source = ? AND entity_id = ? AND explicit_name = 1",
        [source, "clan:有虞氏"]
      ).map { |row| row.fetch("name_chn") }
      assert_includes clan_names, "有虞氏"

      members = db.execute(
        "SELECT person_id FROM clan_members WHERE clan_source = ? AND clan_id = ? ORDER BY person_id",
        [source, "clan:有虞氏"]
      ).map { |row| row.fetch("person_id") }
      assert_includes members, "shun"
      assert_includes members, "qiongchan"

      xia_members = db.execute(
        "SELECT person_id FROM clan_members WHERE clan_source = ? AND clan_id = ? ORDER BY person_id",
        [source, "clan:有夏氏"]
      ).map { |row| row.fetch("person_id") }
      assert_includes xia_members, "gun"
      assert_includes xia_members, "yu"

      metadata = db.execute("SELECT key, value FROM metadata").to_h
      path = Rails.root.join("data", "three_sovereigns_five_emperors.xlsx")
      assert_equal "three_sovereigns_five_emperors.xlsx", metadata.fetch("high_antiquity_filename")
      assert_equal Digest::SHA256.file(path).hexdigest, metadata.fetch("high_antiquity_sha256")
      assert_equal HistoricalAuthorityIndexStaticNames::AUTHORITY_SCHEMA_REVISION, metadata.fetch("authority_schema_revision")
      assert_operator metadata.fetch("clans").to_i, :>=, 5
      assert_operator metadata.fetch("clan_memberships").to_i, :>=, 10
      assert_includes %w[shang_people.xlsx shang_xia.xlsx], metadata.fetch("supplementary_filename")
    ensure
      db&.close
    end
  end
end
