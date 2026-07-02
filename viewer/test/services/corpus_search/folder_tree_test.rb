require_relative "../../test_helper"
require "fileutils"
require "tmpdir"

class CorpusSearchFolderTreeTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname.new(Dir.mktmpdir("folder-tree"))
    @cache_store = CorpusSearch::CacheStore.new(root: @directory.join("cache"))
    @manifest = Struct.new(:documents, :generated_at).new(
      [
        document("中國漢文/clean/周朝/詩經/詩經.txt", "canonical"),
        document("中國漢文/clean/周朝/詩經/variants/版本甲.txt", "textual_variant"),
        document("中國漢文/raw/周朝/詩經.txt", "raw"),
        document("日本漢文/clean/江戶時代/詩.txt", "canonical"),
        document("scripts/readme.txt", "support")
      ],
      "2026-07-02T00:00:00Z"
    )
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
  end

  test "builds a shallow checkbox tree from searchable document folders" do
    tree = CorpusSearch::FolderTree.load(manifest: @manifest, cache_store: @cache_store)

    assert_equal %w[中國漢文 日本漢文], tree.roots.map { |node| node["path"] }

    china = tree.roots.first
    assert_equal 3, china["document_count"]
    assert_equal %w[中國漢文/clean 中國漢文/raw], china["children"].map { |node| node["path"] }

    clean = china["children"].first
    assert_equal ["中國漢文/clean/周朝"], clean["children"].map { |node| node["path"] }
    assert_equal 2, clean["children"].first["document_count"]
  end

  test "reuses the cached tree for the same manifest generation" do
    first = CorpusSearch::FolderTree.load(manifest: @manifest, cache_store: @cache_store)
    @manifest.documents.clear
    second = CorpusSearch::FolderTree.load(manifest: @manifest, cache_store: @cache_store)

    assert_equal first.roots, second.roots
    assert_equal %w[中國漢文 日本漢文], second.roots.map { |node| node["path"] }
  end

  private

  def document(path, role)
    {
      "path" => path,
      "folder_path" => File.dirname(path),
      "document_role" => role
    }
  end
end
