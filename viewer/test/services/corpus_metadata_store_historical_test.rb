# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"

class CorpusMetadataStoreHistoricalTest < ActiveSupport::TestCase
  test "BOM metadata preserves child categories and only explicit compilation chronology is inherited separately" do
    Dir.mktmpdir do |directory|
      root = Pathname(directory)
      compilation = root.join("中國漢文", "clean", "詩經")
      child = compilation.join("國風")
      FileUtils.mkdir_p(child)
      child.join("國風.txt").write("關關雎鳩", encoding: "UTF-8")

      write_bom_json(compilation.join("metadata.json"), {
        "work_id" => 100,
        "title" => "詩經",
        "is_compilation" => true,
        "date_label" => "ca. Western Zhou–Spring and Autumn",
        "year_start" => -1046,
        "year_end" => -476,
        "period" => "周",
        "categories" => ["經", "Compilation"],
        "worklist" => [{ "work_id" => 200 }]
      })
      write_bom_json(child.join("metadata.json"), {
        "work_id" => 200,
        "title" => "國風",
        "categories" => ["詩"],
        "contained_in" => [{ "work_id" => 100 }],
        "documents" => [{ "file" => "國風.txt" }]
      })

      store = CorpusMetadataStore.new(root: root)
      metadata = store.search_metadata_for_path("中國漢文/clean/詩經/國風/國風.txt")
      assert_equal ["詩"], metadata.fetch("categories")
      assert_equal 100, metadata.fetch("compilation_work_id")
      assert_equal "詩經", metadata.fetch("compilation_title")
      assert_equal(-1046, metadata.fetch("compilation_year_start"))
      assert_equal(-476, metadata.fetch("compilation_year_end"))
      assert_nil metadata["year_start"]
      assert_equal 2, store.metadata_dependency_paths_for("中國漢文/clean/詩經/國風/國風.txt").length
    end
  end

  test "date_label-only metadata receives conservative numeric chronology" do
    Dir.mktmpdir do |directory|
      root = Pathname(directory)
      work = root.join("中國漢文", "clean", "近代文")
      FileUtils.mkdir_p(work)
      work.join("近代文.txt").write("文", encoding: "UTF-8")
      write_bom_json(work.join("metadata.json"), {
        "work_id" => 300,
        "title" => "近代文",
        "date_label" => "1940年",
        "period" => "中華民國",
        "documents" => [{ "file" => "近代文.txt" }]
      })

      store = CorpusMetadataStore.new(root: root)
      metadata = store.search_metadata_for_path("中國漢文/clean/近代文/近代文.txt")
      assert_equal 1940, metadata.fetch("year_start")
      assert_equal 1940, metadata.fetch("year_end")
      assert_equal "date_label_absolute", metadata.fetch("date_resolution_source")
      assert_equal "explicit_label", metadata.fetch("date_resolution_confidence")
      assert_nil metadata["date_resolution_authority_kind"]
    end
  end

  test "metadata dependency expansion accepts an array of child metadata paths" do
    Dir.mktmpdir do |directory|
      root = Pathname(directory)
      compilation = root.join("中國漢文", "clean", "總集")
      first = compilation.join("甲篇")
      second = compilation.join("乙篇")
      FileUtils.mkdir_p(first)
      FileUtils.mkdir_p(second)

      write_bom_json(compilation.join("metadata.json"), {
        "work_id" => 400,
        "title" => "總集",
        "is_compilation" => true,
        "worklist" => [{ "work_id" => 401 }, { "work_id" => 402 }]
      })
      write_bom_json(first.join("metadata.json"), {
        "work_id" => 401,
        "title" => "甲篇",
        "contained_in" => [{ "work_id" => 400 }]
      })
      write_bom_json(second.join("metadata.json"), {
        "work_id" => 402,
        "title" => "乙篇",
        "contained_in" => [{ "work_id" => 400 }]
      })

      store = CorpusMetadataStore.new(root: root)
      dependencies = store.metadata_dependency_paths_for_metadata_path([
        first.join("metadata.json"),
        [second.join("metadata.json")]
      ])

      assert_equal 3, dependencies.length
      assert_includes dependencies, first.join("metadata.json")
      assert_includes dependencies, second.join("metadata.json")
      assert_includes dependencies, compilation.join("metadata.json")
    end
  end

  private

  def write_bom_json(path, value)
    path.binwrite("\xEF\xBB\xBF".b + JSON.pretty_generate(value).encode(Encoding::UTF_8).b)
  end
end
