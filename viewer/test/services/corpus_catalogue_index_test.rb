# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "tmpdir"

class CorpusCatalogueIndexTest < ActiveSupport::TestCase
  setup do
    @tmpdir = Pathname.new(Dir.mktmpdir("corpus-catalogue"))
    @corpus_root = @tmpdir.join("corpus")
    @cache_store = CorpusSearch::CacheStore.new(root: @tmpdir.join("cache"))
    @corpus_root.mkpath
  end

  teardown do
    FileUtils.remove_entry(@tmpdir) if @tmpdir&.exist?
  end

  test "catalogue is work-metadata based and includes a work with no text document" do
    write_work(
      "中國漢文/clean/漢朝/西漢/史記",
      work_id: 10,
      title: "史記",
      author: "Sima, Qian 司馬遷",
      year: -91
    )
    write_work(
      "中國漢文/clean/漢朝/西漢/漢書",
      work_id: 20,
      title: "漢書",
      author: "Ban, Gu 班固 & Ban, Zhao 班昭",
      year: 82
    )

    index = build_index

    assert_equal 2, index.work_count
    assert_equal ["史記"], index.timeline(query: "史記").items.map { |row| row.fetch("display_title") }
    assert_equal ["史記", "漢書"], index.timeline(geography: false).items.map { |row| row.fetch("display_title") }
  end

  test "timeline chronology and geography are independent dimensions" do
    write_work("中國漢文/clean/周朝/甲", work_id: 1, title: "甲", year: -300, macro_region: "中國")
    write_work("日本漢文/clean/平安時代/乙", work_id: 2, title: "乙", year: 900, macro_region: "日本")
    write_work("中國漢文/clean/宋朝/丙", work_id: 3, title: "丙", year: 1100, macro_region: "中國")

    index = build_index

    assert_equal %w[甲 乙 丙], index.timeline(order: "asc", geography: false).items.map { |row| row.fetch("display_title") }
    assert_equal %w[丙 乙 甲], index.timeline(order: "desc", geography: false).items.map { |row| row.fetch("display_title") }
    assert_equal %w[甲 丙 乙], index.timeline(order: "asc", geography: true).items.map { |row| row.fetch("display_title") }
  end

  test "book-title brackets and simplified title spellings use hidden search keys without changing display title" do
    write_work(
      "中國漢文/clean/漢朝/西漢/論語",
      work_id: 1,
      title: "《國語》",
      year: -150,
      categories: ["經部"]
    )

    index = build_index

    result = index.timeline(query: "国语", geography: false).items.first
    assert_equal "《國語》", result.fetch("display_title")
    assert_equal "國語", result.fetch("base_title")
    assert_equal ["經部"], result.fetch("categories")
  end

  test "direct authority variants do not conflate distinct traditional siblings" do
    write_work(
      "中國漢文/clean/漢朝/西漢/髮記",
      work_id: 30,
      title: "髮記",
      year: 1
    )

    index = build_index

    assert_equal ["髮記"], index.timeline(query: "发记", geography: false).items.map { |row| row.fetch("display_title") }
    assert_empty index.timeline(query: "發記", geography: false).items
  end


  test "metadata in derived normalisation folders does not create another catalogue work" do
    write_work("中國漢文/clean/漢朝/西漢/史記", work_id: 10, title: "史記", year: -91)
    write_work("中國漢文/clean/漢朝/西漢/史記/normalisations/某本", work_id: 999, title: "史記校本", year: -91)

    index = build_index

    assert_equal 1, index.work_count
    assert_empty index.timeline(query: "校本").items
  end

  test "author lookup uses the same work-level catalogue" do
    write_work("中國漢文/clean/漢朝/西漢/史記", work_id: 10, title: "史記", author: "Sima, Qian 司馬遷", year: -91)
    write_work("中國漢文/clean/漢朝/西漢/漢書", work_id: 20, title: "漢書", author: "Ban, Gu 班固", year: 82)

    index = build_index

    assert_equal ["史記"], index.works_for_author(names: ["司馬遷"]).map { |row| row.fetch("display_title") }
  end

  test "duplicate work ids collapse to one preferred work row" do
    write_work("中國漢文/clean/漢朝/西漢/史記", work_id: 10, title: "史記", author: "Sima, Qian 司馬遷", year: -91)
    write_work("中國漢文/clean/漢朝/西漢/史記別本", work_id: 10, title: "史記別本", year: -91)

    index = build_index

    assert_equal 1, index.work_count
    assert_equal ["史記"], index.timeline(geography: false).items.map { |row| row.fetch("display_title") }
  end

  test "undated works use dynastic or folder periods for chronological placement" do
    write_work("中國漢文/clean/唐朝/無年唐書", work_id: 101, title: "無年唐書", year: nil, period: "唐朝")
    write_work("中國漢文/clean/宋朝/有年宋書", work_id: 102, title: "有年宋書", year: 1050, period: "宋朝")
    write_work("中國漢文/clean/清朝/無年清書", work_id: 103, title: "無年清書", year: nil)

    index = build_index

    assert_equal %w[無年唐書 有年宋書 無年清書], index.timeline(order: "asc", geography: false).items.map { |row| row.fetch("display_title") }
    assert_equal %w[無年清書 有年宋書 無年唐書], index.timeline(order: "desc", geography: false).items.map { |row| row.fetch("display_title") }
  end

  test "person lookup includes authors editors and named contributor roles" do
    write_work("中國漢文/clean/漢朝/史記", work_id: 201, title: "史記", year: -91, author: "Sima, Qian 司馬遷")
    write_work(
      "中國漢文/clean/漢朝/圖錄", work_id: 202, title: "圖錄", year: nil,
      contributors: [{ "name" => "Sima, Qian 司馬遷", "role" => "painting; inscription" }]
    )

    index = build_index
    rows = index.works_for_person(names: ["司馬遷"])

    by_title = rows.index_by { |row| row.fetch("display_title") }
    assert_equal ["author"], by_title.fetch("史記").fetch("credit_roles")
    assert_equal ["inscription", "painting"], by_title.fetch("圖錄").fetch("credit_roles").sort

    people = index.people_matching(query: "司馬遷")
    assert people.any? { |person| person["name"].include?("司馬遷") && person["work_count"] == 2 }
    profile = index.corpus_person("司馬遷")
    assert profile.fetch("name").include?("司馬遷")
  end

  private

  def build_index
    CorpusCatalogueIndex.build!(
      root: @corpus_root,
      cache_store: @cache_store,
      store: unavailable_authority_store
    )
  end

  def unavailable_authority_store
    HistoricalAuthorityStore.new(
      cbdb_path: nil,
      cbdb_release: {},
      lookup_path: nil,
      historical_path: nil,
      cache_store: @cache_store,
      logger: nil
    )
  end

  def write_work(relative, work_id:, title:, year:, author: nil, macro_region: "中國", categories: [], period: "", polity: "", editors: [], contributors: [])
    directory = @corpus_root.join(relative)
    directory.mkpath
    corpus_root = relative.start_with?("日本漢文/") ? "日本漢文" : "中國漢文"
    payload = {
      "schema_version" => 1,
      "work_id" => work_id,
      "title" => title,
      "work_base_title" => title,
      "authors" => author ? [author] : [],
      "date_label" => year.to_s,
      "year_start" => year,
      "year_end" => year,
      "corpus_root" => corpus_root,
      "macro_region" => macro_region,
      "period" => period,
      "polity" => polity,
      "editors" => editors,
      "contributors" => contributors,
      "region" => "",
      "categories" => categories,
      "documents" => []
    }
    directory.join("metadata.json").write("\uFEFF#{JSON.pretty_generate(payload)}\n", mode: "w:UTF-8")
  end
end
