require_relative "../../test_helper"

class GrammarCorpusSearchDefinitionTest < ActiveSupport::TestCase
  test "normalises a prepared proximity search" do
    search = Grammar::CorpusSearchDefinition.normalize_all([
      {
        mode: "proximity",
        term_a: "以",
        term_b: "為",
        distance: "20",
        order: "a_before_b"
      }
    ]).first

    assert_equal "proximity", search["mode"]
    assert_equal 20, search["distance"]
    assert_equal "a_before_b", search["order"]
  end

  test "rejects an incomplete proximity search" do
    error = assert_raises(ArgumentError) do
      Grammar::CorpusSearchDefinition.normalize_all([
        { mode: "proximity", term_a: "以", term_b: "" }
      ])
    end

    assert_match(/requires term_b/, error.message)
  end
end
