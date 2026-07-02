require_relative "../../test_helper"

class CorpusSearchSearchDefinitionTest < ActiveSupport::TestCase
  test "defaults to canonical documents and punctuation-insensitive exact matching" do
    definition = CorpusSearch::SearchDefinition.new(query_text: "孝")

    assert_equal ["canonical"], definition.document_roles
    assert_equal ["canonical"], definition.manifest_filters["document_roles"]
    assert_equal "ignore", definition.punctuation
    assert_equal "exact", definition.character_equivalence
  end

  test "normalizes folders and rejects support as a searchable role" do
    definition = CorpusSearch::SearchDefinition.new(
      query_text: "孝",
      document_roles: ["canonical", "support", "textual_variant"],
      include_folders: ["/中國漢文\\clean\\周朝/"],
      exclude_folders: ["中國漢文/clean/周朝/不詳/"]
    )

    assert_equal %w[canonical textual_variant], definition.document_roles
    assert_equal ["中國漢文/clean/周朝", "日本漢文/clean/江戶時代"], definition.include_folders
    assert_equal ["中國漢文/clean/周朝/不詳"], definition.exclude_folders
  end

  test "presentation options clamp display-only values" do
    options = CorpusSearch::PresentationOptions.new(context: 999, page: 0, per_page: 500)

    assert_equal 200, options.context
    assert_equal 1, options.page
    assert_equal 50, options.per_page
  end
end
