require_relative "../../test_helper"
require "fileutils"
require "tmpdir"

class CorpusSearchRunnerCorrectnessTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname.new(Dir.mktmpdir("runner-correctness"))
    @corpus_root = @directory.join("corpus")
    @cache_root = @directory.join("cache")
    @cache_store = CorpusSearch::CacheStore.new(root: @cache_root)

    write("中國漢文/clean/周朝/metadata_only.txt", "# TITLE: 關關雎鳩\n\n無匹配正文\n")
    write("中國漢文/clean/周朝/body.txt", "# TITLE: Body\n\n關關雎鳩，在河之洲。\n")
    write("中國漢文/clean/周朝/variants/variant.txt", "關關雎鳩\n")
    write("中國漢文/raw/周朝/raw.txt", "關關雎鳩\n")
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
  end

  test "exact search cannot hit metadata raw files or textual variants by default" do
    Rails.configuration.x.stub(:corpus_root, @corpus_root) do
      manifest = quietly do
        CorpusSearch::Manifest.load(
          root: @corpus_root,
          cache_store: @cache_store,
          refresh: true,
          force: true
        )
      end
      query = CorpusSearch::Query.new(term_a: "關關雎鳩")
      page = CorpusSearch::Runner.new(
        query: query,
        manifest: manifest,
        cache_store: @cache_store
      ).page

      assert_equal 1, page.total
      hit = page.hits.fetch(0)
      assert_equal "中國漢文/clean/周朝/body.txt", hit["path"]
      assert_equal "canonical", hit["document_role"]
      assert_equal "關關雎鳩", hit["matched_text"]
    end
  end

  test "textual variants can be selected deliberately without entering canonical statistics" do
    Rails.configuration.x.stub(:corpus_root, @corpus_root) do
      manifest = quietly do
        CorpusSearch::Manifest.load(
          root: @corpus_root,
          cache_store: @cache_store,
          refresh: true,
          force: true
        )
      end
      query = CorpusSearch::Query.new(
        term_a: "關關雎鳩",
        document_roles: ["textual_variant"]
      )
      page = CorpusSearch::Runner.new(
        query: query,
        manifest: manifest,
        cache_store: @cache_store
      ).page

      assert_equal 1, page.total
      assert_equal "textual_variant", page.hits.fetch(0)["document_role"]
      assert_equal "中國漢文/clean/周朝", page.hits.fetch(0)["canonical_parent_path"]
    end
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
