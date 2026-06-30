require_relative "../../test_helper"

class GrammarMarkdownDocumentTest < ActiveSupport::TestCase
  test "parses front matter and recognises a distinct references heading" do
    document = Grammar::MarkdownDocument.parse(<<~MARKDOWN)
      ---
      id: fw-u4e4b
      kind: function_word
      ---

      ## Explanation

      Text.

      ## References

      Reference.
    MARKDOWN

    assert_equal "fw-u4e4b", document.metadata["id"]
    assert document.references_heading?
  end

  test "removes submitter-supplied publication metadata" do
    document = Grammar::MarkdownDocument.parse(<<~MARKDOWN)
      ---
      id: fw-u4e4b
      published_at: 1900-01-01
      contributors:
        - name: Invented
          role: editor
      ---

      ## References
    MARKDOWN

    cleaned = Grammar::MarkdownDocument.parse(document.without_publication_metadata)

    refute cleaned.metadata.key?("published_at")
    refute cleaned.metadata.key?("contributors")
  end

  test "rejects unclosed front matter" do
    error = assert_raises(ArgumentError) do
      Grammar::MarkdownDocument.parse("---\nid: broken\n")
    end

    assert_match(/Unclosed YAML front matter/, error.message)
  end
end
