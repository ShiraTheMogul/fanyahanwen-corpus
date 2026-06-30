require_relative "../../test_helper"
require "fileutils"
require "tmpdir"

class GrammarSubmissionAndPublisherTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname.new(Dir.mktmpdir("grammar-publisher"))
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
    YAML
    @store = Grammar::EntryStore.new(root: @directory)
    @validator = Grammar::SubmissionValidator.new(store: @store)
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
  end

  test "normalises structural metadata and strips publication claims" do
    result = @validator.validate!(
      entry_id: "fw-u4e4b",
      action: "create",
      locale: "en",
      raw_markdown: <<~MARKDOWN,
        ---
        id: wrong
        kind: concept
        contributors:
          - name: Invented
            role: editor
        published_at: 1900-01-01
        ---

        ## Explanation

        Explanation.

        ## References

        Reference.
      MARKDOWN
      public_name: "Example Author",
      orcid: "0000-0002-1825-0097",
      credit_role: "author",
      licence_agreed: "1"
    )

    assert_equal "fw-u4e4b", result.document.metadata["id"]
    assert_equal "function_word", result.document.metadata["kind"]
    refute result.document.metadata.key?("contributors")
    refute result.document.metadata.key?("published_at")
    assert_equal "0000-0002-1825-0097", result.credit["orcid"]
  end

  test "requires CC BY agreement and references" do
    error = assert_raises(Grammar::SubmissionValidator::ValidationError) do
      @validator.validate!(
        entry_id: "fw-u4e4b",
        action: "create",
        locale: "en",
        raw_markdown: "## Explanation\n\nNo references.\n",
        public_name: "Example",
        orcid: "",
        credit_role: "author",
        licence_agreed: "0"
      )
    end

    assert_match(/CC BY/, error.message)
  end

  test "publisher adds accepted credit and reviewer metadata" do
    result = @validator.validate!(
      entry_id: "fw-u4e4b",
      action: "create",
      locale: "en",
      raw_markdown: "## Explanation\n\nText.\n\n## References\n\nReference.\n",
      public_name: "Example Author",
      orcid: "0000-0002-1825-0097",
      credit_role: "author",
      licence_agreed: true
    )

    published = Grammar::Publisher.new(
      store: @store,
      reviewer_name: "Llinos",
      today: Date.new(2026, 6, 30)
    ).publish!(
      entry_id: result.entry.id,
      locale: result.locale,
      proposed_markdown: result.markdown,
      credit: result.credit
    )
    document = Grammar::MarkdownDocument.parse(published)

    assert_equal "CC BY", document.metadata["licence"]
    assert_equal "2026-06-30", document.metadata["published_at"]
    assert_equal "2026-06-30", document.metadata["updated_at"]
    assert_includes document.metadata["contributors"], {
      "name" => "Example Author",
      "orcid" => "0000-0002-1825-0097",
      "role" => "author",
      "date" => "2026-06-30"
    }
    assert_includes document.metadata["contributors"], {
      "name" => "Llinos",
      "role" => "editor",
      "date" => "2026-06-30"
    }
  end

  test "translations inherit canonical structure but may use a translated title" do
    source_path = @store.article_path("fw-u4e4b", locale: "en")
    FileUtils.mkdir_p(source_path.dirname)
    source_path.write(Grammar::MarkdownDocument.dump(
      metadata: {
        "id" => "fw-u4e4b",
        "kind" => "function_word",
        "headword" => "之",
        "title" => "之",
        "contributors" => [{ "name" => "Source Author", "role" => "author" }],
        "published_at" => "2026-06-30"
      },
      body: "## Explanation\n\nSource.\n\n## References\n\nReference.\n"
    ))

    editable = Grammar::MarkdownDocument.parse(
      @store.submission_markdown_for("fw-u4e4b", locale: "en")
    )
    refute editable.metadata.key?("contributors")
    refute editable.metadata.key?("published_at")

    result = @validator.validate!(
      entry_id: "fw-u4e4b",
      action: "translate",
      locale: "lzh",
      raw_markdown: <<~MARKDOWN,
        ---
        title: 之字
        categories:
          - should-not-override
        corpus_searches:
          - term_a: 假
        ---

        ## Explanation

        文。

        ## References

        書。
      MARKDOWN
      public_name: "譯者",
      orcid: "",
      credit_role: "translator",
      licence_agreed: true
    )

    assert_equal "之字", result.document.metadata["title"]
    assert_equal "lzh", result.document.metadata["locale"]
    refute result.document.metadata.key?("categories")
    refute result.document.metadata.key?("corpus_searches")
  end

  test "translations require a published source article" do
    error = assert_raises(Grammar::SubmissionValidator::ValidationError) do
      @validator.validate!(
        entry_id: "fw-u4e4b",
        action: "translate",
        locale: "lzh",
        raw_markdown: "## Explanation\n\n文。\n\n## References\n\n書。\n",
        public_name: "譯者",
        orcid: "",
        credit_role: "translator",
        licence_agreed: true
      )
    end

    assert_match(/source article must be published/, error.message)
  end
  test "publishes an accepted unlisted entry and adds it to the catalogue" do
    result = @validator.validate!(
      entry_id: "",
      action: "create",
      locale: "en",
      raw_markdown: "## Explanation\n\nText.\n\n## References\n\nReference.\n",
      public_name: "Example Author",
      orcid: "",
      credit_role: "author",
      licence_agreed: true,
      entry_attributes: {
        "kind" => "function_word",
        "headword" => "爾們",
        "title" => "爾們"
      }
    )

    Grammar::Publisher.new(
      store: @store,
      reviewer_name: "Llinos",
      today: Date.new(2026, 6, 30)
    ).publish!(
      entry_id: result.entry.id,
      locale: result.locale,
      proposed_markdown: result.markdown,
      credit: result.credit,
      catalogue_entry: result.catalogue_entry
    )

    published_entry = @store.find!("fw-u723e-u5011")
    assert_equal "function_words/爾們/index.md", published_entry.path
    assert @store.article_path(published_entry, locale: "en").file?
    assert_equal 1, @store.all.count { |entry| entry.id == "fw-u723e-u5011" }
  end

end
