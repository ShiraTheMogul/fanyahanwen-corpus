# frozen_string_literal: true

require "test_helper"

class GrammarArticleSearchesTest < ActiveSupport::TestCase
  test "adds an exact headword search for an unconfigured single character entry" do
    entry = Grammar::Entry.new(
      "id" => "fw-u4e0d",
      "kind" => "function_word",
      "headword" => "不",
      "title" => "不",
      "path" => "function_words/不/index.md"
    )

    assert_equal(
      [{ "mode" => "exact", "term_a" => "不" }],
      Grammar::ArticleSearches.for(entry: entry, article_metadata: {})
    )
  end

  test "does not add a fallback to multi-character entries" do
    entry = Grammar::Entry.new(
      "id" => "pattern-test",
      "kind" => "pattern",
      "headword" => "何以",
      "title" => "何以",
      "path" => "patterns/何以/index.md"
    )

    assert_empty Grammar::ArticleSearches.for(entry: entry, article_metadata: {})
  end


  test "does not add a fallback to a multi-character function-word entry" do
    entry = Grammar::Entry.new(
      "id" => "fw-u4e0d-u4ea6",
      "kind" => "function_word",
      "headword" => "不亦",
      "title" => "不亦",
      "path" => "function_words/不亦/index.md"
    )

    assert_empty Grammar::ArticleSearches.for(entry: entry, article_metadata: {})
  end

  test "keeps configured searches instead of adding a duplicate fallback" do
    entry = Grammar::Entry.new(
      "id" => "fw-u4e0d",
      "kind" => "function_word",
      "headword" => "不",
      "title" => "不",
      "path" => "function_words/不/index.md",
      "corpus_searches" => [{ "mode" => "exact", "term_a" => "不亦" }]
    )

    assert_equal(
      [{ "mode" => "exact", "term_a" => "不亦" }],
      Grammar::ArticleSearches.for(entry: entry, article_metadata: {})
    )
  end
end
