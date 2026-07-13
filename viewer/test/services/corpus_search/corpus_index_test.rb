require_relative "../../test_helper"
require "fileutils"
require "tmpdir"

class CorpusSearchCorpusIndexTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname.new(Dir.mktmpdir("corpus-index"))
    @cache_store = CorpusSearch::CacheStore.new(root: @directory.join("cache"))
    @manifest = Struct.new(:documents, :generated_at).new(
      [
        document("doc-1", "work-1", "中國漢文/clean/周朝/甲/甲.txt", "中國漢文", "中國", "周", "周朝", "魯", "canonical"),
        document("doc-2", "work-1", "中國漢文/clean/周朝/甲/乙.txt", "中國漢文", "中國", "周", "周朝", "魯", "canonical"),
        document("doc-3", "work-2", "日本漢文/clean/江戶時代/丙.txt", "日本漢文", "日本", "日本", "江戶時代", "江戶", "canonical"),
        document("doc-4", nil, "scripts/readme.txt", nil, nil, nil, nil, nil, "support")
      ],
      "2026-07-13T00:00:00Z"
    )
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
  end

  test "builds compact JSON metadata facets and folder tree from manifest" do
    index = CorpusSearch::CorpusIndex.build!(manifest: @manifest, cache_store: @cache_store)

    assert_equal 3, index.document_count
    assert_equal 2, index.work_count
    assert_equal 2, index.facets.dig("corpus_root", "中國漢文")
    assert_equal 1, index.facets.dig("period", "江戶時代")
    assert_equal %w[中國漢文 日本漢文], index.folder_tree.roots.map { |node| node["path"] }
  end

  test "web load reads prepared index without the manifest" do
    built = CorpusSearch::CorpusIndex.build!(manifest: @manifest, cache_store: @cache_store)
    loaded = CorpusSearch::CorpusIndex.load(cache_store: @cache_store)

    assert_equal built.document_count, loaded.document_count
    assert_equal built.work_count, loaded.work_count
    assert_equal built.facets, loaded.facets
    assert_equal built.folder_tree.roots, loaded.folder_tree.roots
  end

  private

  def document(id, work_id, path, corpus_root, macro_region, polity, period, region, role)
    {
      "id" => id,
      "document_id" => id,
      "work_id" => work_id,
      "path" => path,
      "folder_path" => File.dirname(path),
      "corpus_root" => corpus_root,
      "macro_region" => macro_region,
      "polity" => polity,
      "period" => period,
      "region" => region,
      "document_role" => role
    }
  end
end
