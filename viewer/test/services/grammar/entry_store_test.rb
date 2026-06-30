require_relative "../../test_helper"
require "fileutils"
require "tmpdir"

class GrammarEntryStoreTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname.new(Dir.mktmpdir("grammar-store"))
    FileUtils.mkdir_p(@directory.join("_templates"))
    @directory.join("_templates/function_word.md").write("## Explanation\n\n## References\n")
    @directory.join("catalogue.yml").write(<<~YAML)
      version: 1
      source_locale: en
      entries:
        - id: fw-u4e4b
          kind: function_word
          headword: 之
          title: 之
          path: function_words/之/index.md
          importance: core
          categories:
            - pronoun
    YAML
    @store = Grammar::EntryStore.new(root: @directory)
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
  end

  test "validates the catalogue and builds locale-specific paths" do
    assert @store.validate_catalogue!
    entry = @store.find!("fw-u4e4b")

    assert_equal @directory.join("function_words/之/index.md"), @store.article_path(entry, locale: :en)
    assert_equal @directory.join("function_words/之/index.lzh.md"), @store.article_path(entry, locale: :lzh)
  end

  test "falls back to the source article without claiming a translation exists" do
    entry = @store.find!("fw-u4e4b")
    path = @store.article_path(entry, locale: :en)
    FileUtils.mkdir_p(path.dirname)
    path.write(<<~MARKDOWN)
      ---
      id: fw-u4e4b
      kind: function_word
      headword: 之
      title: 之
      ---

      ## References
    MARKDOWN

    loaded = @store.load(entry, locale: :lzh)

    assert loaded.published?
    assert loaded.fallback
    assert_equal "en", loaded.locale
    refute @store.article_exists?(entry, locale: :lzh)
  end

  test "template fixes structural metadata from the catalogue" do
    template = Grammar::MarkdownDocument.parse(
      @store.template_for("fw-u4e4b", locale: :lzh)
    )

    assert_equal "fw-u4e4b", template.metadata["id"]
    assert_equal "function_word", template.metadata["kind"]
    assert_equal "之", template.metadata["headword"]
    assert_equal "lzh", template.metadata["locale"]
  end
end
