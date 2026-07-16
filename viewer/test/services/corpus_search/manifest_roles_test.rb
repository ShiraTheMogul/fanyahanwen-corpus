require_relative "../../test_helper"
require "fileutils"
require "tmpdir"

class CorpusSearchManifestRolesTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname.new(Dir.mktmpdir("manifest-roles"))
    @corpus_root = @directory.join("corpus")
    @cache_root = @directory.join("cache")

    write("中國漢文/clean/周朝/詩經/詩經.txt", "# TITLE: 詩經\n\n正文\n")
    write("中國漢文/clean/周朝/詩經/variants/版本甲.txt", "版本正文\n")
    write("中國漢文/clean/周朝/詩經/kanbun/詩經.txt", "訓讀\n")
    write("中國漢文/raw/周朝/詩經.txt", "原始抓取\n")
    write("notes/readme.txt", "support\n")

    @cache_store = CorpusSearch::CacheStore.new(root: @cache_root)
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
  end

  test "manifest records roles and defaults to canonical text only" do
    manifest = quietly do
      CorpusSearch::Manifest.load(
        root: @corpus_root,
        cache_store: @cache_store,
        refresh: true,
        force: true
      )
    end

    roles = manifest.documents.to_h { |doc| [doc["path"], doc["document_role"]] }
    assert_equal "canonical", roles["中國漢文/clean/周朝/詩經/詩經.txt"]
    assert_equal "textual_variant", roles["中國漢文/clean/周朝/詩經/variants/版本甲.txt"]
    assert_equal "derived_reading", roles["中國漢文/clean/周朝/詩經/kanbun/詩經.txt"]
    assert_equal "raw", roles["中國漢文/raw/周朝/詩經.txt"]
    assert_equal "support", roles["notes/readme.txt"]

    assert_equal ["中國漢文/clean/周朝/詩經/詩經.txt"], manifest.filtered.map { |doc| doc["path"] }
  end

  test "folder filters include descendants and exclusions" do
    write("中國漢文/clean/漢朝/史記.txt", "史記\n")
    manifest = quietly do
      CorpusSearch::Manifest.load(
        root: @corpus_root,
        cache_store: @cache_store,
        refresh: true,
        force: true
      )
    end

    selected = manifest.filtered(
      "include_folders" => ["中國漢文/clean"],
      "exclude_folders" => ["中國漢文/clean/漢朝"]
    )

    assert_equal ["中國漢文/clean/周朝/詩經/詩經.txt"], selected.map { |doc| doc["path"] }
  end

  test "uses stable JSON document and work ids" do
    write("中國漢文/clean/隋朝/三論玄義/三論玄義__juan_01.txt", "正文\n")
    metadata = @corpus_root.join("中國漢文/clean/隋朝/三論玄義/metadata.json")
    metadata.write(JSON.pretty_generate(
      "work_id" => 80029,
      "title" => "三論玄義",
      "corpus_root" => "中國漢文",
      "macro_region" => "中國",
      "period" => "隋朝",
      "polity" => "隋",
      "documents" => [
        {
          "document_id" => 174261,
          "file" => "三論玄義__juan_01.txt",
          "path" => "中國漢文/clean/隋朝/三論玄義/三論玄義__juan_01.txt"
        }
      ]
    ))

    manifest = quietly do
      CorpusSearch::Manifest.load(
        root: @corpus_root,
        cache_store: @cache_store,
        refresh: true,
        force: true
      )
    end
    document = manifest.documents.find { |doc| doc["path"].end_with?("三論玄義__juan_01.txt") }

    assert_equal "174261", document["id"]
    assert_equal "80029", document["work_id"]
    assert_equal "中國", document["macro_region"]
    assert_equal "隋", document["polity"]
  end

  test "unbounded user query requires an existing full manifest and never scans" do
    query = CorpusSearch::Query.from_params(q: "正文", search: "1")

    assert_raises(CorpusSearch::Manifest::CacheMissing) do
      quietly do
        CorpusSearch::Manifest.load_for_query(
          query: query,
          root: @corpus_root,
          cache_store: @cache_store
        )
      end
    end

    assert_not @cache_store.absolute(CorpusSearch::Manifest::CACHE_PATH).exist?
  end

  test "bounded user query also reuses full manifest and never writes a scoped manifest" do
    quietly do
      CorpusSearch::Manifest.load(
        root: @corpus_root,
        cache_store: @cache_store,
        refresh: true,
        force: true
      )
    end

    query = CorpusSearch::Query.from_params(
      q: "正文",
      search: "1",
      folders: ["中國漢文/clean/周朝"]
    )

    manifest = quietly do
      CorpusSearch::Manifest.load_for_query(
        query: query,
        root: @corpus_root,
        cache_store: @cache_store
      )
    end

    assert_equal 5, manifest.documents.length
    scoped_caches = @cache_root.glob("**/*scoped*")
    assert_empty scoped_caches
  end

  test "unbounded user query reuses administrator-built full manifest" do
    quietly do
      CorpusSearch::Manifest.load(
        root: @corpus_root,
        cache_store: @cache_store,
        refresh: true,
        force: true
      )
    end
    query = CorpusSearch::Query.from_params(q: "正文", search: "1")

    manifest = quietly do
      CorpusSearch::Manifest.load_for_query(
        query: query,
        root: @corpus_root,
        cache_store: @cache_store
      )
    end

    assert_equal 5, manifest.documents.length
  end

  test "invalid UTF-8 documents are excluded and reported without replacing the scan" do
    bad = @corpus_root.join("中國漢文/clean/周朝/壞字節.txt")
    FileUtils.mkdir_p(bad.dirname)
    File.binwrite(bad, "正文\xFF".b)

    manifest = quietly do
      CorpusSearch::Manifest.load(
        root: @corpus_root,
        cache_store: @cache_store,
        refresh: true,
        force: true
      )
    end

    assert_not manifest.documents.any? { |doc| doc["path"].end_with?("壞字節.txt") }
    report = Rails.root.join("tmp/corpus_search_manifest_audit/manifest_scan_issues.csv")
    assert_includes report.read, "invalid_utf8"
    assert_includes report.read, "壞字節.txt"
  end

  private

  def write(relative, content)
    path = @corpus_root.join(relative)
    FileUtils.mkdir_p(path.dirname)
    path.write(content)
  end

  def quietly
    old = ENV["CORPUS_SEARCH_SILENT"]
    ENV["CORPUS_SEARCH_SILENT"] = "1"
    yield
  ensure
    ENV["CORPUS_SEARCH_SILENT"] = old
  end
end
