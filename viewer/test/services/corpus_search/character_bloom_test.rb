require_relative "../../test_helper"

class CorpusSearchCharacterBloomTest < ActiveSupport::TestCase
  test "records present characters without claiming absent characters" do
    bloom = CorpusSearch::CharacterBloom.build("人之初，性本善。")

    assert CorpusSearch::CharacterBloom.maybe_includes?(bloom, "人")
    assert CorpusSearch::CharacterBloom.maybe_includes?(bloom, "善")
    refute CorpusSearch::CharacterBloom.maybe_includes?(bloom, "龘")
  end

  test "checks exact and alternative term requirements" do
    bloom = CorpusSearch::CharacterBloom.build("關關雎鳩，在河之洲。")
    exact = ["關關雎鳩".chars.map { |character| Set[character] }]
    alternatives = [
      "不存在".chars.map { |character| Set[character] },
      "河之洲".chars.map { |character| Set[character] }
    ]

    assert CorpusSearch::CharacterBloom.maybe_matches?(bloom, term_patterns: exact)
    assert CorpusSearch::CharacterBloom.maybe_matches?(bloom, term_patterns: alternatives, alternatives: true)
  end
end
