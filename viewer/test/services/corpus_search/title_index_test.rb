require_relative "../../test_helper"
require "fileutils"
require "tmpdir"

class CorpusSearchTitleIndexTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname.new(Dir.mktmpdir("title-index"))
    @cache_store = CorpusSearch::CacheStore.new(root: @directory.join("cache"))
    @manifest = Struct.new(:documents, :generated_at).new(
      [
        document(
          id: "doc-1",
          work_id: "work-1",
          title: "漢書",
          work: "漢書",
          path: "中國漢文/clean/漢朝/漢書/漢書.txt",
          macro_region: "中國",
          period: "漢朝",
          year_start: -111
        ),
        document(
          id: "doc-2",
          work_id: "work-2",
          title: "後漢書",
          work: "後漢書",
          path: "中國漢文/clean/南北朝/後漢書/後漢書.txt",
          macro_region: "中國",
          period: "南北朝",
          year_start: 432
        ),
        document(
          id: "doc-3",
          work_id: "work-3",
          title: "漢書地理志",
          work: "漢書地理志",
          path: "日本漢文/clean/江戶時代/漢書地理志/漢書地理志.txt",
          macro_region: "日本",
          period: "江戶時代",
          year_start: 1750
        ),
        document(
          id: "doc-4",
          work_id: "work-4",
          title: "史記（三家注本）",
          work: "史記",
          path: "中國漢文/clean/唐朝/史記（三家注本）/史記.txt",
          macro_region: "中國",
          period: "唐朝",
          year_start: 736
        ),
        document(
          id: "doc-5",
          work_id: "work-5",
          title: "漢書",
          work: "漢書",
          path: "中國漢文/clean/漢朝/漢書/normalisations/漢書.txt",
          macro_region: "中國",
          period: "漢朝",
          year_start: -111
        )
      ],
      "2026-08-22T00:00:00Z"
    )
  end

  teardown do
    FileUtils.rm_rf(@directory)
  end

  test "builds one searchable row per work and preserves displayed titles" do
    index = CorpusSearch::TitleIndex.build!(manifest: @manifest, cache_store: @cache_store)

    assert_equal 4, index.work_count
    results = index.search(query: "漢書", group_geography: false)

    assert_equal "漢書", results.first.fetch("title")
    assert_equal "exact_title", results.first.fetch("match_kind")
    assert_equal ["漢書", "後漢書", "漢書地理志"], results.map { |row| row.fetch("title") }
  end

  test "exact base-title matches keep the fuller displayed title unchanged" do
    index = CorpusSearch::TitleIndex.build!(manifest: @manifest, cache_store: @cache_store)

    result = index.search(query: "史記", group_geography: false).find { |row| row["work_id"] == "work-4" }

    assert result
    assert_equal "史記（三家注本）", result.fetch("title")
    assert_equal "史記", result.fetch("base_title")
    assert_equal "exact_base_title", result.fetch("match_kind")
  end

  test "geography grouping remains primary while chronology is reversible inside a group" do
    index = CorpusSearch::TitleIndex.build!(manifest: @manifest, cache_store: @cache_store)

    earliest = index.search(query: "漢", group_geography: true, chronology: "asc")
    latest = index.search(query: "漢", group_geography: true, chronology: "desc")

    assert_equal ["漢書", "後漢書"], earliest.select { |row| row["macro_region"] == "中國" }.map { |row| row["title"] }
    assert_equal ["後漢書", "漢書"], latest.select { |row| row["macro_region"] == "中國" }.map { |row| row["title"] }
    assert_equal "日本", earliest.last.fetch("macro_region")
  end

  test "broad character normalisation finds simplified or traditional title forms without rewriting the result" do
    index = CorpusSearch::TitleIndex.build!(manifest: @manifest, cache_store: @cache_store)

    result = index.search(query: "汉书", group_geography: false).find { |row| row["work_id"] == "work-1" }

    assert result
    assert_equal "漢書", result.fetch("title")
    assert_equal "variant_normalised", result.fetch("match_kind")
  end

  private

  def document(id:, work_id:, title:, work:, path:, macro_region:, period:, year_start:)
    {
      "id" => id,
      "work_id" => work_id,
      "title" => title,
      "work" => work,
      "path" => path,
      "folder_path" => File.dirname(path),
      "document_role" => "canonical",
      "author" => "",
      "date_text" => "",
      "nation" => macro_region,
      "corpus_root" => path.split("/").first,
      "macro_region" => macro_region,
      "period" => period,
      "polity" => "",
      "region" => "",
      "categories" => [],
      "year_start" => year_start,
      "year_end" => year_start
    }
  end
end
