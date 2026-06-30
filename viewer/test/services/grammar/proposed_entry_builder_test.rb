require_relative "../../test_helper"
require "fileutils"
require "tmpdir"

class GrammarProposedEntryBuilderTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname.new(Dir.mktmpdir("grammar-proposed-entry"))
    FileUtils.mkdir_p(@directory.join("_templates"))
    @directory.join("_templates/function_word.md").write("## Explanation\n\n## References\n")
    @directory.join("_templates/function.md").write("## Explanation\n\n## References\n")
    @directory.join("catalogue.yml").write(<<~YAML)
      version: 1
      source_locale: en
      entries:
        - id: fw-u723e
          kind: function_word
          headword: 爾
          title: 爾
          path: function_words/爾/index.md
    YAML
    @store = Grammar::EntryStore.new(root: @directory)
    @builder = Grammar::ProposedEntryBuilder.new(store: @store)
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
  end

  test "derives an unlisted function-word ID and path" do
    entry = @builder.build!(kind: "function_word", headword: "爾們")

    assert_equal "fw-u723e-u5011", entry.id
    assert_equal "function_words/爾們/index.md", entry.path
    assert_equal "爾們", entry.title
  end

  test "derives a child function beneath its parent" do
    entry = @builder.build!(
      kind: "function",
      headword: "爾",
      title: "Plural 爾",
      parent_id: "fw-u723e",
      label: "plural use"
    )

    assert_equal "fw-u723e-plural-use", entry.id
    assert_equal "function_words/爾/functions/plural_use.md", entry.path
    assert_equal "fw-u723e", entry.parent_id
  end

  test "refuses an ID already present in the catalogue" do
    error = assert_raises(Grammar::ProposedEntryBuilder::ValidationError) do
      @builder.build!(kind: "function_word", headword: "爾")
    end

    assert_match(/already exists/, error.message)
  end
end
