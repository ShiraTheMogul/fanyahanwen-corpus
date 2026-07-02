require_relative "../../test_helper"
require "fileutils"
require "tmpdir"

class CorpusSearchRunnerCorrectnessTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname.new(Dir.mktmpdir("runner-correctness"))
    @corpus_root = @directory.join("corpus")
    @cache_root = @directory.join("cache")
    @cache_store = CorpusSearch::CacheStore.new(root: @cache_root)

    write("中國漢文/clean/周朝/metadata_only.txt", "# TITLE: 關關雎鳩在河之洲\n\n無匹配正文\n")
    write("中國漢文/clean/周朝/body.txt", "# TITLE: Body\n\n關關雎鳩，在河之洲。\n")
    write("中國漢文/clean/周朝/proximity.txt", "# TITLE: Proximity\n\n舜，克孝，聞於天下。\n")
    write("中國漢文/clean/周朝/repeated.txt", "# TITLE: Repeated\n\n民與民共事君。\n")
    write("中國漢文/clean/周朝/variants/variant.txt", "關關雎鳩在河之洲\n")
    write("中國漢文/raw/周朝/raw.txt", "關關雎鳩在河之洲\n")
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
  end

  test "punctuation-free exact sequences find punctuated source text at original offsets" do
    page = run_query(
      CorpusSearch::SearchDefinition.new(
        query_text: "關關雎鳩在河之洲",
        punctuation: "ignore"
      )
    )

    assert_equal 1, page.total
    hit = page.hits.fetch(0)
    assert_equal "中國漢文/clean/周朝/body.txt", hit["path"]
    assert_equal "關關雎鳩，在河之洲", hit["matched_text"]
    assert_equal 0, hit["start_offset"]
    assert_equal 9, hit["end_offset"]
    assert_equal 0, hit["search_start_offset"]
    assert_equal 8, hit["search_end_offset"]
  end

  test "respecting punctuation requires the entered punctuation" do
    no_match = run_query(
      CorpusSearch::SearchDefinition.new(
        query_text: "關關雎鳩在河之洲",
        punctuation: "respect"
      )
    )
    matching = run_query(
      CorpusSearch::SearchDefinition.new(
        query_text: "關關雎鳩，在河之洲",
        punctuation: "respect"
      )
    )

    assert_equal 0, no_match.total
    assert_equal 1, matching.total
  end

  test "metadata raw files and textual variants remain excluded by default" do
    page = run_query(CorpusSearch::SearchDefinition.new(query_text: "關關雎鳩"))

    assert_equal 1, page.total
    assert_equal "canonical", page.hits.fetch(0)["document_role"]
  end

  test "canonical and textual-variant layers can be searched together" do
    page = run_query(
      CorpusSearch::SearchDefinition.new(
        query_text: "關關雎鳩在河之洲",
        document_roles: ["textual_variant", "canonical"]
      )
    )

    assert_equal 2, page.total
    assert_equal %w[canonical textual_variant], page.hits.map { |hit| hit["document_role"] }.sort
  end

  test "textual variants can be selected deliberately" do
    page = run_query(
      CorpusSearch::SearchDefinition.new(
        query_text: "關關雎鳩在河之洲",
        document_roles: ["textual_variant"]
      )
    )

    assert_equal 1, page.total
    assert_equal "textual_variant", page.hits.fetch(0)["document_role"]
    assert_equal "中國漢文/clean/周朝", page.hits.fetch(0)["canonical_parent_path"]
  end

  test "proximity span is measured on the punctuation-normalized stream" do
    page = run_query(
      CorpusSearch::SearchDefinition.new(
        mode: "proximity",
        terms: ["舜", "孝"],
        maximum_span: 3,
        order: "entered",
        punctuation: "ignore"
      )
    )

    assert_equal 1, page.total
    assert_equal "舜，克孝", page.hits.fetch(0)["matched_text"]
  end


  test "proximity supports three or more terms" do
    page = run_query(
      CorpusSearch::SearchDefinition.new(
        mode: "proximity",
        terms: ["舜", "孝", "天下"],
        maximum_span: 8,
        order: "entered",
        punctuation: "ignore"
      )
    )

    assert_equal 1, page.total
    hit = page.hits.fetch(0)
    assert_equal "舜，克孝，聞於天下", hit["matched_text"]
    assert_equal 3, hit["term_matches"].length
    assert_equal ["舜", "孝", "天下"], hit["term_matches"].map { |match| match["term"] }
  end

  test "repeated proximity terms need separate source occurrences" do
    page = run_query(
      CorpusSearch::SearchDefinition.new(
        mode: "proximity",
        terms: ["民", "民", "君"],
        maximum_span: 8,
        order: "entered",
        punctuation: "ignore"
      )
    )

    assert_equal 1, page.total
    assert_equal [0, 2, 5], page.hits.fetch(0)["term_matches"].map { |match| match["start_offset"] }
  end

  test "entered proximity order rejects reversed terms" do
    page = run_query(
      CorpusSearch::SearchDefinition.new(
        mode: "proximity",
        terms: ["孝", "舜"],
        maximum_span: 3,
        order: "entered",
        punctuation: "ignore"
      )
    )

    assert_equal 0, page.total
  end

  private

  def run_query(definition)
    presentation = CorpusSearch::PresentationOptions.new
    query = CorpusSearch::Query.new(
      search_definition: definition,
      presentation_options: presentation,
      requested: true
    )

    Rails.configuration.x.stub(:corpus_root, @corpus_root) do
      manifest = quietly do
        CorpusSearch::Manifest.load(
          root: @corpus_root,
          cache_store: @cache_store,
          refresh: true,
          force: true
        )
      end

      CorpusSearch::Runner.new(
        query: query,
        manifest: manifest,
        cache_store: @cache_store
      ).page
    end
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
