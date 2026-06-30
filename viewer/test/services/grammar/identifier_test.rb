require_relative "../../test_helper"

class GrammarIdentifierTest < ActiveSupport::TestCase
  test "uses Unicode code points and reports collisions without overwriting" do
    candidate = Grammar::Identifier.generate(kind: "function_word", headword: "之")

    assert_equal "fw-u4e4b", candidate
    assert Grammar::Identifier.collision?(candidate, ["fw-u4e4b"])
    assert_equal "fw-u4e4b-3", Grammar::Identifier.next_available(
      candidate,
      ["fw-u4e4b", "fw-u4e4b-2"]
    )
  end

  test "individual functions keep the parent identifier" do
    assert_equal "fw-u4e4b-attributive", Grammar::Identifier.generate(
      kind: "function",
      headword: "之",
      parent_id: "fw-u4e4b",
      label: "Attributive"
    )
  end
end
