require_relative "../../test_helper"
require "set"

class CorpusSearchFastScannerTest < ActiveSupport::TestCase
  test "native string scanning preserves overlapping exact matches" do
    searchable = CorpusSearch::NormalizedText.build("人人人", punctuation: "respect")
    pattern = [Set["人"], Set["人"]]

    assert_equal [0, 1], CorpusSearch::SearchText.positions_of_pattern(searchable, pattern)
  end

  test "native anchor scanning preserves character-equivalence matches" do
    searchable = CorpusSearch::NormalizedText.build("後世后世", punctuation: "respect")
    pattern = [Set["後", "后"], Set["世"]]

    assert_equal [0, 2], CorpusSearch::SearchText.positions_of_pattern(searchable, pattern)
  end

  test "native string offsets remain normalized character offsets" do
    searchable = CorpusSearch::NormalizedText.build("甲，乙丙", punctuation: "ignore")
    pattern = [Set["乙"], Set["丙"]]

    assert_equal "甲乙丙", searchable.text
    assert_equal [1], CorpusSearch::SearchText.positions_of_pattern(searchable, pattern)
    assert_equal [2, 4], searchable.original_range(1, 3)
  end

  test "byte scanning maps mixed ASCII and Han back to character offsets" do
    searchable = CorpusSearch::NormalizedText.build("A甲A甲", punctuation: "respect")
    pattern = [Set["A"], Set["甲"]]

    assert_equal [0, 2], CorpusSearch::SearchText.positions_of_pattern(searchable, pattern)
  end

  test "regex scanner omits zero-width matches and returns character offsets" do
    searchable = CorpusSearch::NormalizedText.build("甲乙丙", punctuation: "respect")

    assert_equal [], CorpusSearch::RegexPattern.new("(?=乙)").ranges_in(searchable)
    assert_equal [[1, 2]], CorpusSearch::RegexPattern.new("乙").ranges_in(searchable)
  end
end
