require_relative "../../test_helper"

class CorpusSearchCharacterPatternTest < ActiveSupport::TestCase
  test "finds an equivalent source form while preserving its original offset" do
    registry = CorpusSearch::CharacterEquivalenceRegistry.new(level: "broad")
    pattern = CorpusSearch::CharacterPattern.build(
      "試驗",
      punctuation: "ignore",
      registry: registry
    )
    searchable = CorpusSearch::NormalizedText.build("試，験", punctuation: "ignore")

    assert_equal [0], pattern.positions_in(searchable.units)
    match = pattern.equivalence_matches_at(searchable: searchable, search_start: 0, term_index: 0).fetch(0)

    assert_equal "驗", match.fetch("query_character")
    assert_equal "験", match.fetch("source_character")
    assert_equal 2, match.fetch("source_offset")
    assert_equal 1, match.fetch("source_search_offset")
  end
end
