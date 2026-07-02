require_relative "../../test_helper"

class CorpusSearchQueryParamsTest < ActiveSupport::TestCase
  test "parses the canonical exact-query parameters" do
    query = CorpusSearch::QueryParams.parse(
      {
        mode: "exact",
        q: "關關雎鳩在河之洲",
        punctuation: "ignore",
        characters: "exact",
        roles: ["canonical"],
        folders: ["中國漢文/clean/周朝"],
        context: 30,
        page: 2
      }
    )

    assert query.valid?
    assert query.requested?
    assert_equal "關關雎鳩在河之洲", query.query_text
    assert_equal ["中國漢文/clean/周朝"], query.include_folders
    assert_equal 30, query.context
    assert_equal 2, query.page
  end

  test "serializes a deterministic live URL without the page" do
    query = CorpusSearch::QueryParams.parse(
      {
        mode: "exact",
        q: "關關雎鳩在河之洲",
        punctuation: "ignore",
        characters: "exact",
        roles: ["canonical"],
        folders: ["中國漢文/clean/周朝"],
        page: 4
      }
    )

    assert_equal(
      "/corpus/search?mode=exact&q=%E9%97%9C%E9%97%9C%E9%9B%8E%E9%B3%A9%E5%9C%A8%E6%B2%B3%E4%B9%8B%E6%B4%B2&punctuation=ignore&characters=exact&roles[]=canonical&folders[]=%E4%B8%AD%E5%9C%8B%E6%BC%A2%E6%96%87%2Fclean%2F%E5%91%A8%E6%9C%9D",
      query.relative_url(include_presentation: false)
    )
    assert_not_includes query.relative_url(include_presentation: false), "page="
  end

  test "proximity parameters use term arrays" do
    query = CorpusSearch::QueryParams.parse(
      mode: "proximity",
      terms: ["舜", "孝"],
      span: 80,
      order: "entered",
      punctuation: "ignore"
    )

    assert query.valid?
    assert_equal %w[舜 孝], query.terms
    assert_equal 80, query.maximum_span
    assert_equal "entered", query.order
  end
  test "matching cache identity is shared across interface locales" do
    english = CorpusSearch::QueryParams.parse({ mode: "exact", q: "孝" }, locale: :en)
    literary_chinese = CorpusSearch::QueryParams.parse({ mode: "exact", q: "孝" }, locale: :lzh)

    assert_equal english.cache_key, literary_chinese.cache_key
  end

end
