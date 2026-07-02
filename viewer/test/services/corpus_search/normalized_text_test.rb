require_relative "../../test_helper"

class CorpusSearchNormalizedTextTest < ActiveSupport::TestCase
  test "ignores punctuation whitespace and zero-width formatting with an offset map" do
    text = "關關雎鳩，\n在河之洲。\u200B"
    normalized = CorpusSearch::NormalizedText.build(text, punctuation: "ignore")

    assert_equal "關關雎鳩在河之洲", normalized.text
    assert_equal [0, 1, 2, 3, 6, 7, 8, 9], normalized.original_offsets
    assert_equal [0, 10], normalized.original_range(0, 8)
  end

  test "respected punctuation remains in the searchable stream" do
    text = "關關雎鳩，在河之洲。"
    normalized = CorpusSearch::NormalizedText.build(text, punctuation: "respect")

    assert_equal text, normalized.text
    assert_equal [4, 5], normalized.original_range(4, 5)
  end
end
