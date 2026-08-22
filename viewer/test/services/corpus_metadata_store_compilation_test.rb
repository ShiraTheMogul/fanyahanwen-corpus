# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "json"
require "tmpdir"

class CorpusMetadataStoreCompilationTest < ActiveSupport::TestCase
  test "keeps child chronology separate from enclosing compilation chronology" do
    Dir.mktmpdir do |directory|
      root = Pathname(directory)
      compilation = root.join("中國漢文", "clean", "周朝", "詩經")
      child = compilation.join("周南", "關雎")
      FileUtils.mkdir_p(child)

      write_json(compilation.join("metadata.json"), {
        "schema_version" => 1,
        "work_id" => 100,
        "title" => "詩經",
        "work_base_title" => "詩經",
        "is_compilation" => true,
        "date_label" => "ca. 200 BCE",
        "year_start" => -250,
        "year_end" => -150,
        "worklist" => [
          {
            "work_id" => 101,
            "title" => "關雎",
            "edition_id" => 61,
            "edition_label" => "詩經本"
          }
        ]
      })
      write_json(child.join("metadata.json"), {
        "schema_version" => 1,
        "work_id" => 101,
        "title" => "關雎",
        "work_base_title" => "關雎",
        "date_label" => "ca. 700 BCE",
        "year_start" => -750,
        "year_end" => -650,
        "categories" => ["詩經", "國風"],
        "contained_in" => [
          {
            "work_id" => 100,
            "title" => "詩經",
            "edition_id" => 61,
            "edition_label" => "詩經本"
          }
        ],
        "documents" => [
          {
            "document_id" => 1001,
            "file" => "關雎.txt",
            "path" => "中國漢文/clean/周朝/詩經/周南/關雎/關雎.txt"
          }
        ]
      })
      child.join("關雎.txt").binwrite("\uFEFF關關雎鳩，在河之洲。\n")

      fs = CorpusFs.new(root: root.to_s)
      store = CorpusMetadataStore.new(root: root.to_s, fs: fs, logger: nil)
      metadata = store.search_metadata_for_path("中國漢文/clean/周朝/詩經/周南/關雎/關雎.txt")

      assert_equal(-750, metadata.fetch("year_start"))
      assert_equal(-650, metadata.fetch("year_end"))
      assert_equal("ca. 700 BCE", metadata.fetch("date_text"))
      assert_equal("100", metadata.fetch("compilation_work_id").to_s)
      assert_equal("詩經", metadata.fetch("compilation_title"))
      assert_equal(-250, metadata.fetch("compilation_year_start"))
      assert_equal(-150, metadata.fetch("compilation_year_end"))
      assert_equal ["詩經", "國風"], metadata.fetch("categories")

      dependencies = store.metadata_dependency_paths_for("中國漢文/clean/周朝/詩經/周南/關雎/關雎.txt")
        .map { |path| Pathname(path).relative_path_from(root).to_s.tr("\\", "/") }
      assert_equal [
        "中國漢文/clean/周朝/詩經/周南/關雎/metadata.json",
        "中國漢文/clean/周朝/詩經/metadata.json"
      ], dependencies

      # Mere directory nesting must not manufacture a scholarly relationship.
      unrelated = compilation.join("附錄", "無關")
      FileUtils.mkdir_p(unrelated)
      write_json(unrelated.join("metadata.json"), {
        "schema_version" => 1,
        "work_id" => 999,
        "title" => "無關",
        "year_start" => -100,
        "year_end" => -90,
        "documents" => [{ "document_id" => 9991, "file" => "無關.txt" }]
      })
      unrelated.join("無關.txt").binwrite("\uFEFF無關。\n")
      unrelated_metadata = store.search_metadata_for_path("中國漢文/clean/周朝/詩經/附錄/無關/無關.txt")
      assert_nil unrelated_metadata["compilation_work_id"]

      cache_store = CorpusSearch::CacheStore.new(root: root.join("cache"))
      manifest = CorpusSearch::Manifest.new(root: root.to_s, cache_store: cache_store)
      text_path = child.join("關雎.txt")
      fingerprint_before = manifest.send(
        :fingerprint_for,
        File.stat(text_path),
        store.metadata_dependency_paths_for("中國漢文/clean/周朝/詩經/周南/關雎/關雎.txt")
      )
      File.open(compilation.join("metadata.json"), "ab") { |file| file.write(" ") }
      fingerprint_after = manifest.send(
        :fingerprint_for,
        File.stat(text_path),
        store.metadata_dependency_paths_for("中國漢文/clean/周朝/詩經/周南/關雎/關雎.txt")
      )
      refute_equal fingerprint_before, fingerprint_after
    end
  end

  private

  def write_json(path, payload)
    path.binwrite("\uFEFF#{JSON.pretty_generate(payload)}\n")
  end
end
