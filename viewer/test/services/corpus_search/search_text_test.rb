require_relative "../../test_helper"
require "set"

class CorpusSearchSearchTextTest < ActiveSupport::TestCase
  test "finds overlapping literal matches" do
    assert_equal [0, 1, 2], CorpusSearch::SearchText.positions_of("aaaa", "aa")
  end

  test "matches accepted character alternatives at each position" do
    pattern = [Set["天", "靝"], Set["地"]]

    assert_equal [0, 2], CorpusSearch::SearchText.positions_of_pattern(%w[天 地 靝 地], pattern)
  end

  test "does not match when only a later pattern unit agrees" do
    pattern = [Set["天"], Set["地"]]

    assert_equal [], CorpusSearch::SearchText.positions_of_pattern(%w[人 地], pattern)
  end
end
