require_relative "../../test_helper"

class CorpusSearchSearchDefinitionTest < ActiveSupport::TestCase
  test "defaults to canonical documents and punctuation-insensitive exact matching" do
    definition = CorpusSearch::SearchDefinition.new(query_text: "孝")

    assert_equal ["canonical"], definition.document_roles
    assert_equal ["canonical"], definition.manifest_filters["document_roles"]
    assert_equal "ignore", definition.punctuation
    assert_equal "common", definition.character_equivalence
  end

  test "normalizes folders and rejects support as a searchable role" do
    definition = CorpusSearch::SearchDefinition.new(
      query_text: "孝",
      document_roles: ["canonical", "support", "textual_variant"],
      include_folders: ["/中國漢文\\clean\\周朝/"],
      exclude_folders: ["中國漢文/clean/周朝/不詳/"]
    )

    assert_equal %w[canonical textual_variant], definition.document_roles
    assert_equal ["中國漢文/clean/周朝"], definition.include_folders
    assert_equal ["中國漢文/clean/周朝/不詳"], definition.exclude_folders
  end

  test "preserves repeated proximity terms and validates the ten term limit" do
    valid_terms = Array.new(10, "民")
    valid = CorpusSearch::Query.new(
      search_definition: CorpusSearch::SearchDefinition.new(mode: "proximity", terms: valid_terms),
      presentation_options: CorpusSearch::PresentationOptions.new,
      requested: true
    )
    invalid = CorpusSearch::Query.new(
      search_definition: CorpusSearch::SearchDefinition.new(mode: "proximity", terms: valid_terms + ["君"]),
      presentation_options: CorpusSearch::PresentationOptions.new,
      requested: true
    )

    assert_equal 10, valid.terms.length
    assert valid.valid?
    assert_not invalid.valid?
    assert_includes invalid.errors.join(" "), "10"
  end



  test "alternative mode preserves terms and requires at least two" do
    valid = CorpusSearch::Query.new(
      search_definition: CorpusSearch::SearchDefinition.new(mode: "alternatives", terms: ["仁", "義"]),
      presentation_options: CorpusSearch::PresentationOptions.new,
      requested: true
    )
    invalid = CorpusSearch::Query.new(
      search_definition: CorpusSearch::SearchDefinition.new(mode: "alternatives", terms: ["仁"]),
      presentation_options: CorpusSearch::PresentationOptions.new,
      requested: true
    )

    assert valid.alternatives?
    assert valid.valid?
    assert_not invalid.valid?
  end

  test "accepts all three character-equivalence levels" do
    assert_equal "exact", CorpusSearch::SearchDefinition.new(query_text: "驗", character_equivalence: "exact").character_equivalence
    assert_equal "common", CorpusSearch::SearchDefinition.new(query_text: "驗", character_equivalence: "common").character_equivalence
    assert_equal "broad", CorpusSearch::SearchDefinition.new(query_text: "驗", character_equivalence: "broad").character_equivalence
  end

  test "presentation options clamp display-only values" do
    options = CorpusSearch::PresentationOptions.new(context: 999, page: 0, per_page: 500)

    assert_equal 200, options.context
    assert_equal 1, options.page
    assert_equal 50, options.per_page
  end
end
