require_relative "../../test_helper"

class GrammarIndexBuilderTest < ActiveSupport::TestCase
  test "keeps individual uses inside their function-word tile by default" do
    parent = Grammar::Entry.new(
      "id" => "fw-u4e4b",
      "kind" => "function_word",
      "headword" => "之",
      "title" => "之",
      "path" => "function_words/之/index.md",
      "importance" => "core"
    )
    child = Grammar::Entry.new(
      "id" => "fw-u4e4b-attributive",
      "kind" => "function",
      "headword" => "之",
      "title" => "Attributive 之",
      "path" => "function_words/之/functions/attributive.md",
      "parent" => "fw-u4e4b",
      "importance" => "core",
      "categories" => ["attribution"]
    )

    parent_row = Grammar::IndexBuilder::Row.new(entry: parent, published: false, status: "article_needed")
    child_row = Grammar::IndexBuilder::Row.new(entry: child, published: false, status: "article_needed")
    builder = Grammar::IndexBuilder.new(store: Struct.new(:all).new([parent, child]))
    builder.define_singleton_method(:build_rows) do |include_pronunciation:, include_frequency:|
      [parent_row, child_row]
    end

    default_rows = builder.rows
    assert_equal [parent_row], default_rows
    assert_equal [child_row], parent_row.children

    function_rows = builder.rows(kind: "function")
    assert_equal [child_row], function_rows

    category_rows = builder.rows(category: "attribution")
    assert_equal [child_row], category_rows
  end
end
