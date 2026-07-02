require_relative "../../test_helper"

class CorpusSearchComparisonDefinitionTest < ActiveSupport::TestCase
  test "accepts two distinct groups in a supported dimension" do
    comparison = CorpusSearch::ComparisonDefinition.new(
      dimension: "period",
      left_group: "北宋",
      right_group: "南宋"
    )

    assert comparison.requested?
    assert comparison.valid?
    assert_equal "北宋 ↔ 南宋", comparison.display_label
  end

  test "rejects unsupported, missing, and identical groups" do
    unsupported = CorpusSearch::ComparisonDefinition.new(
      dimension: "author",
      left_group: "甲",
      right_group: "乙"
    )
    assert_not unsupported.valid?

    identical = CorpusSearch::ComparisonDefinition.new(
      dimension: "nation",
      left_group: "日本",
      right_group: "日本"
    )
    assert_not identical.valid?
    assert identical.errors.any? { |error| error.include?("different") }
  end

  test "round trips through a plain hash" do
    original = CorpusSearch::ComparisonDefinition.new(
      dimension: "folder",
      left_group: "中國漢文 / 周朝",
      right_group: "日本漢文 / 江戶時代"
    )

    restored = CorpusSearch::ComparisonDefinition.from_h(original.to_h)

    assert_equal original.to_h, restored.to_h
  end
end
