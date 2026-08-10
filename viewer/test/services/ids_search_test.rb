require_relative "../test_helper"

class IdsSearchTest < ActiveSupport::TestCase
  setup do
    CharacterStructureComponent.delete_all
    CharacterStructure.delete_all
    @clear = make_structure("清", "⿰氵青")
    @river = make_structure("河", "⿰氵可")
    @top_bottom = make_structure("菁", "⿱艹青")
  end

  test "exact search matches the normalised IDS" do
    result = Ids::Search.new.exact("⿰ 氵 青")

    assert_equal [@clear.id], result.map { |row| row.structure.id }
    assert_equal 1.0, result.first.score
  end

  test "fuzzy search prefers shared components and structure" do
    result = Ids::Search.new.fuzzy("⿰氵青")

    assert_equal @clear.id, result.first.structure.id
    river = result.find { |row| row.structure.id == @river.id }
    top_bottom = result.find { |row| row.structure.id == @top_bottom.id }

    assert river, "expected a shared-component candidate using the same ⿰ structure"
    assert top_bottom, "expected a shared-component candidate using a different ⿱ structure"
    assert_operator river.score, :>, top_bottom.score
  end

  private

  def make_structure(glyph, expression)
    character = CharacterData::CodepointResolver.resolve(codepoint: glyph.ord, glyph: glyph)
    tree = Ids::Parser.parse(expression)
    structure = CharacterStructure.create!(
      character_codepoint: character,
      system: "ids",
      expression: expression,
      normalized_expression: expression,
      top_level_operator: Ids::Parser.top_operator(tree),
      component_signature: Ids::Parser.leaves(tree).join(" "),
      operator_signature: Ids::Parser.operators(tree).join(" "),
      leaf_count: Ids::Parser.leaves(tree).length,
      source: "test",
      source_level: "test",
      glyph_region: ""
    )
    Ids::Parser.component_rows(tree).each { |attrs| structure.components.create!(attrs) }
    structure
  end
end
