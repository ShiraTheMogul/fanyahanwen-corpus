require_relative "../../test_helper"

class GrammarIndexBuilderTest < ActiveSupport::TestCase
  test "keeps individual uses inside their function-word tile by default" do
    parent = entry(
      id: "fw-u4e4b",
      kind: "function_word",
      headword: "之",
      title: "之",
      path: "function_words/之/index.md",
      importance: "core"
    )
    child = entry(
      id: "fw-u4e4b-attributive",
      kind: "function",
      headword: "之",
      title: "Attributive 之",
      path: "function_words/之/functions/attributive.md",
      parent: "fw-u4e4b",
      importance: "core",
      categories: ["attribution"]
    )

    parent_row = row(parent)
    child_row = row(child)
    builder = builder_for([parent, child], [parent_row, child_row])

    default_rows = builder.rows
    assert_equal [parent_row], default_rows
    assert_equal [child_row], parent_row.children

    function_rows = builder.rows(kind: "function")
    assert_equal [child_row], function_rows

    category_rows = builder.rows(category: "attribution")
    assert_equal [child_row], category_rows

    importance_rows = builder.rows(sort: "importance")
    assert_equal [parent_row, child_row], importance_rows
  end

  test "uses section headers for importance and entry type arrangements" do
    core = entry(id: "fw-core", kind: "function_word", headword: "之", importance: "core")
    common = entry(id: "pattern-common", kind: "pattern", headword: "以為", importance: "common")
    rows = [row(core), row(common)]
    builder = builder_for([core, common], rows)

    importance_groups = builder.groups(rows, sort: "importance")
    assert_equal %w[core common], importance_groups.map(&:value)
    assert_equal [[rows.first], [rows.last]], importance_groups.map(&:rows)

    kind_groups = builder.groups(rows, sort: "kind")
    assert_equal %w[function_word pattern], kind_groups.map(&:value)
  end

  test "places entries in every applicable category section" do
    multi = entry(
      id: "fw-multi",
      kind: "function_word",
      headword: "焉",
      categories: %w[pronouns_and_interrogatives particles]
    )
    particle = entry(
      id: "fw-particle",
      kind: "function_word",
      headword: "也",
      categories: ["particles"]
    )
    rows = [row(multi), row(particle)]
    builder = builder_for([multi, particle], rows)

    groups = builder.groups(rows, sort: "category")
    assert_equal %w[pronouns_and_interrogatives particles], groups.map(&:value)
    assert_equal [multi], groups.first.rows.map(&:entry)
    assert_equal [multi, particle], groups.last.rows.map(&:entry)
  end

  test "groups pronunciation by a visible initial and removes tone marks" do
    first = entry(id: "fw-zhi", kind: "function_word", headword: "之")
    second = entry(id: "fw-zhe", kind: "function_word", headword: "者")
    missing = entry(id: "fw-missing", kind: "function_word", headword: "兮")
    rows = [
      row(first, pronunciation: "zhī"),
      row(second, pronunciation: "zhě"),
      row(missing, pronunciation: nil)
    ]
    builder = builder_for([first, second, missing], rows)

    groups = builder.groups(rows, sort: "pronunciation")
    assert_equal ["Z", nil], groups.map(&:value)
    assert_equal [first, second], groups.first.rows.map(&:entry)
    assert_equal [missing], groups.last.rows.map(&:entry)
  end

  test "offers category as an arrangement" do
    assert_includes Grammar::IndexBuilder::SORTS, "category"
  end

  private

  def entry(id:, kind:, headword:, title: nil, path: nil, importance: nil, categories: [], parent: nil)
    Grammar::Entry.new(
      "id" => id,
      "kind" => kind,
      "headword" => headword,
      "title" => title || headword,
      "path" => path || "#{id}.md",
      "importance" => importance,
      "categories" => categories,
      "parent" => parent
    )
  end

  def row(entry, pronunciation: nil)
    Grammar::IndexBuilder::Row.new(
      entry: entry,
      published: false,
      status: "article_needed",
      pronunciation: pronunciation,
      children: []
    )
  end

  def builder_for(entries, rows)
    builder = Grammar::IndexBuilder.new(store: Struct.new(:all).new(entries))
    builder.define_singleton_method(:build_rows) do |include_pronunciation:, include_frequency:|
      rows
    end
    builder
  end
end
