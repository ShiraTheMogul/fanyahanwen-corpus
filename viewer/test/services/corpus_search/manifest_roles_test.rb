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
