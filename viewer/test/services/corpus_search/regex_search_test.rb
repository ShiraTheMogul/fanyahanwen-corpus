require_relative "../../test_helper"
require "fileutils"
require "tmpdir"

class CorpusSearchRegexSearchTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname.new(Dir.mktmpdir("regex-search"))
    @corpus_root = @directory.join("corpus")
    @cache_store = CorpusSearch::CacheStore.new(root: @directory.join("cache"))

    write("中國漢文/clean/周朝/body.txt", "# TITLE: 不應由題名命中\n\n天地，玄黃。宇宙洪荒。\n")
    write("中國漢文/clean/周朝/metadata_only.txt", "# TITLE: 天地玄黃\n\n正文無此四字。\n")
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
  end

  test "regex mode matches the normalized body and maps back to source offsets" do
    page = run_query(
      CorpusSearch::SearchDefinition.new(
        mode: "regex",
        query_text: "天地玄[黃黄]",
        punctuation: "ignore",
        character_equivalence: "broad"
      )
    )

    assert_equal 1, page.total
    hit = page.hits.fetch(0)
    assert_equal "中國漢文/clean/周朝/body.txt", hit["path"]
    assert_equal "天地，玄黃", hit["matched_text"]
    assert_equal "exact", hit["character_equivalence"]
    assert_equal 0, hit["search_start_offset"]
    assert_equal 4, hit["search_end_offset"]
  end

  test "regex mode never matches metadata headers" do
    page = run_query(
      CorpusSearch::SearchDefinition.new(
        mode: "regex",
        query_text: "天地玄黃",
        punctuation: "ignore"
      )
    )

    assert_equal 1, page.total
    assert_equal "中國漢文/clean/周朝/body.txt", page.hits.fetch(0)["path"]
  end

  test "regex definitions force exact character matching without rewriting regex syntax" do
    definition = CorpusSearch::SearchDefinition.new(
      mode: "regex",
      query_text: "驗|験",
      character_equivalence: "broad"
    )

    assert definition.regex?
    assert definition.single_term?
    assert_equal "exact", definition.character_equivalence
    assert_equal ["驗|験"], definition.effective_terms
  end

  test "regex definitions preserve significant outer whitespace" do
    definition = CorpusSearch::SearchDefinition.new(
      mode: "regex",
      query_text: " 天地 "
    )

    assert_equal " 天地 ", definition.query_text
  end

  test "invalid regular expressions are rejected before a corpus scan" do
    query = CorpusSearch::QueryParams.parse(mode: "regex", q: "(天地")

    refute query.valid?
    assert query.errors.any? { |error| error.include?("Invalid regular expression") }
  end

  test "regex live URLs keep the expression in q" do
    query = CorpusSearch::QueryParams.parse(
      mode: "regex",
      q: "天地.{0,3}玄黃",
      punctuation: "respect",
      characters: "broad",
      roles: ["canonical"]
    )

    assert query.valid?
    assert query.regex?
    assert_equal "exact", query.character_equivalence
    assert_includes query.relative_url(include_presentation: false), "mode=regex"
    assert_includes query.relative_url(include_presentation: false), "q=%E5%A4%A9%E5%9C%B0.%7B0%2C3%7D%E7%8E%84%E9%BB%83"
    assert_includes query.relative_url(include_presentation: false), "characters=exact"
  end

  test "regex query round trips through prepared-search serialization" do
    query = CorpusSearch::QueryParams.parse(
      mode: "regex",
      q: "天地.{0,3}玄黃",
      punctuation: "ignore",
      roles: ["canonical"]
    )

    restored = CorpusSearch::Query.from_h(query.to_h)

    assert restored.regex?
    assert_equal query.query_text, restored.query_text
    assert_equal "exact", restored.character_equivalence
    assert_equal query.cache_key, restored.cache_key
  end

  private

  def run_query(definition)
    Rails.configuration.x.stub(:corpus_root, @corpus_root) do
      manifest = quietly do
        CorpusSearch::Manifest.load(
          root: @corpus_root,
          cache_store: @cache_store,
          refresh: true,
          force: true
        )
      end
      presentation = CorpusSearch::PresentationOptions.new
      query = CorpusSearch::Query.new(
        search_definition: definition,
        presentation_options: presentation,
        requested: true
      )

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
