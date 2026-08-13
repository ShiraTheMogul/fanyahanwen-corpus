require_relative "../../test_helper"
require "fileutils"
require "tmpdir"

class CorpusSearchManifestQueryCacheTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname.new(Dir.mktmpdir("manifest-query-cache"))
    @corpus_root = @directory.join("corpus")
    @cache_root = @directory.join("cache")
    @cache_store = CorpusSearch::CacheStore.new(root: @cache_root)

    write("中國漢文/clean/周朝/詩經/詩經.txt", "正文\n")
    write("中國漢文/clean/漢朝/史記/史記.txt", "史文\n")
    write("中國漢文/raw/周朝/詩經.txt", "原始抓取\n")
    write("中國漢文/clean/周朝/詩經/translation/eng/test/詩經.txt", "translation\n")
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
  end

  test "refresh builds role caches and a default query loads canonical documents only" do
    full = quietly { rebuild_full_manifest }
    assert_equal 4, full.documents.length

    query_manifest = quietly do
      CorpusSearch::Manifest.load_for_query(
        query: query_for(["canonical"]),
        root: @corpus_root,
        cache_store: @cache_store
      )
    end

    assert_nil query_manifest.instance_variable_get(:@documents)
    assert_equal 2, query_manifest.filtered.length
    assert_equal [
      "中國漢文/clean/周朝/詩經/詩經.txt",
      "中國漢文/clean/漢朝/史記/史記.txt"
    ].sort, query_manifest.filtered.map { |doc| doc["path"] }.sort
  end

  test "query cache combines only the requested searchable roles" do
    quietly { rebuild_full_manifest }

    query_manifest = quietly do
      CorpusSearch::Manifest.load_for_query(
        query: query_for(%w[canonical translation]),
        root: @corpus_root,
        cache_store: @cache_store
      )
    end

    roles = query_manifest.filtered(
      "document_roles" => %w[canonical translation]
    ).map { |doc| doc["document_role"] }.uniq.sort

    assert_equal %w[canonical translation], roles
    assert_equal 3, query_manifest.filtered("document_roles" => %w[canonical translation]).length
  end

  test "folder filtering runs against the preselected role slice" do
    quietly { rebuild_full_manifest }
    query_manifest = quietly do
      CorpusSearch::Manifest.load_for_query(
        query: query_for(["canonical"]),
        root: @corpus_root,
        cache_store: @cache_store
      )
    end

    selected = query_manifest.filtered(
      "document_roles" => ["canonical"],
      "include_folders" => ["中國漢文/clean/周朝"]
    )

    assert_equal ["中國漢文/clean/周朝/詩經/詩經.txt"], selected.map { |doc| doc["path"] }
  end

  test "documents remains a compatibility escape hatch for full-manifest callers" do
    quietly { rebuild_full_manifest }
    query_manifest = quietly do
      CorpusSearch::Manifest.load_for_query(
        query: query_for(["canonical"]),
        root: @corpus_root,
        cache_store: @cache_store
      )
    end

    assert_equal 4, query_manifest.documents.length
  end

  test "query caches can be rebuilt from the existing full cache without rescanning corpus files" do
    quietly { rebuild_full_manifest }
    FileUtils.rm_f(@cache_store.absolute(CorpusSearch::Manifest::QUERY_CACHE_META_PATH))
    FileUtils.rm_rf(@cache_store.absolute(CorpusSearch::Manifest::QUERY_CACHE_DIRECTORY))
    FileUtils.rm_f(@corpus_root.join("中國漢文/clean/周朝/詩經/詩經.txt"))

    quietly do
      CorpusSearch::Manifest.rebuild_query_caches!(
        root: @corpus_root,
        cache_store: @cache_store
      )
    end

    query_manifest = quietly do
      CorpusSearch::Manifest.load_for_query(
        query: query_for(["canonical"]),
        root: @corpus_root,
        cache_store: @cache_store
      )
    end

    assert query_manifest.filtered.any? { |doc| doc["path"].end_with?("詩經/詩經.txt") }
  end

  private

  def query_for(roles)
    Struct.new(:document_roles).new(roles)
  end

  def rebuild_full_manifest
    CorpusSearch::Manifest.load(
      root: @corpus_root,
      cache_store: @cache_store,
      refresh: true,
      force: true
    )
  end

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
