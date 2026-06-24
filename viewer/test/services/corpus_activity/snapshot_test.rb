# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class CorpusActivitySnapshotTest < ActiveSupport::TestCase
  FakeManifest = Struct.new(:documents)

  test "builds canonical latest-text and recent-change feeds" do
    Dir.mktmpdir do |directory|
      store = CorpusSearch::CacheStore.new(root: directory)
      manifest = FakeManifest.new([
        document("中國漢文/clean/晉朝/東晉/方言/方言__卷一.txt", title: "方言/卷一.txt", mtime: 30),
        document("中國漢文/clean/晉朝/東晉/方言/方言__卷二.txt", title: "方言/卷二", mtime: 20),
        document("中國漢文/raw/晉朝/方言.txt", title: "raw", mtime: 100),
        document("中國漢文/clean/晉朝/東晉/方言/translation/eng/abc/方言__卷一.txt", title: "translation", mtime: 200)
      ])

      CorpusActivity::SnapshotBuilder.new(manifest: manifest, cache_store: store).build!
      snapshot = CorpusActivity::Snapshot.new(cache_store: store)

      assert snapshot.available?
      assert_equal 1, snapshot.summary.dig("feeds", "latest_texts", "total")
      assert_equal 2, snapshot.summary.dig("feeds", "recent_changes", "total")

      latest = snapshot.page(kind: "latest_texts", number: 1).fetch("items").first
      assert_equal "方言", latest["title"]
      assert_equal 2, latest["file_count"]

      recent = snapshot.page(kind: "recent_changes", number: 1).fetch("items").first
      assert_equal "方言/卷一", recent["title"]
      assert_equal "中國漢文/clean/晉朝/東晉/方言/方言__卷一", recent["display_path"]
    end
  end

  test "reads the requested page from a shard" do
    Dir.mktmpdir do |directory|
      store = CorpusSearch::CacheStore.new(root: directory)
      documents = 75.times.map do |index|
        document(
          format("中國漢文/clean/晉朝/東晉/作品/作品__%03d.txt", index),
          title: format("作品/%03d", index),
          mtime: index
        )
      end

      CorpusActivity::SnapshotBuilder.new(
        manifest: FakeManifest.new(documents),
        cache_store: store
      ).build!

      page = CorpusActivity::Snapshot.new(cache_store: store).page(kind: "recent_changes", number: 2)

      assert_equal 2, page["page"]
      assert_equal 25, page["items"].length
      assert_equal "作品/000", page["items"].last["title"]
    end
  end

  private

  def document(path, title:, mtime:)
    {
      "path" => path,
      "title" => title,
      "nation" => "中國漢文",
      "period" => "晉朝",
      "region" => "東晉",
      "size" => 123,
      "mtime" => mtime
    }
  end
end
