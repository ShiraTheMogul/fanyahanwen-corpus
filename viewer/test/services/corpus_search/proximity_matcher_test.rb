require_relative "../../test_helper"

class CorpusSearchProximityMatcherTest < ActiveSupport::TestCase
  test "finds three terms in any order within one compact window" do
    matcher = CorpusSearch::ProximityMatcher.new(
      searchable_units: %w[甲 舜 乙 天 下 丙 孝 丁],
      term_units: [%w[舜], %w[孝], %w[天 下]],
      maximum_span: 7,
      order: "any"
    )

    match = matcher.matches.fetch(0)

    assert_equal 1, match.search_start
    assert_equal 7, match.search_end
    assert_equal [0, 1, 2], match.term_matches.map(&:term_index)
    assert_equal [1, 6, 3], match.term_matches.map(&:search_start)
  end

  test "entered order requires the query order" do
    forward = CorpusSearch::ProximityMatcher.new(
      searchable_units: %w[舜 孝 天 下],
      term_units: [%w[舜], %w[孝], %w[天 下]],
      maximum_span: 4,
      order: "entered"
    )
    reversed = CorpusSearch::ProximityMatcher.new(
      searchable_units: %w[舜 孝 天 下],
      term_units: [%w[孝], %w[舜], %w[天 下]],
      maximum_span: 4,
      order: "entered"
    )

    assert_equal 1, forward.matches.length
    assert_empty reversed.matches
  end

  test "repeated terms require distinct occurrences" do
    one_occurrence = CorpusSearch::ProximityMatcher.new(
      searchable_units: %w[民 君],
      term_units: [%w[民], %w[民], %w[君]],
      maximum_span: 3,
      order: "any"
    )
    two_occurrences = CorpusSearch::ProximityMatcher.new(
      searchable_units: %w[民 民 君],
      term_units: [%w[民], %w[民], %w[君]],
      maximum_span: 3,
      order: "any"
    )

    assert_empty one_occurrence.matches
    assert_equal 1, two_occurrences.matches.length
    assert_equal [0, 1, 2], two_occurrences.matches.fetch(0).term_matches.map(&:search_start)
  end

  test "dense passages return compact windows instead of every pair combination" do
    matcher = CorpusSearch::ProximityMatcher.new(
      searchable_units: %w[舜 舜 孝],
      term_units: [%w[舜], %w[孝]],
      maximum_span: 3,
      order: "any"
    )

    assert_equal 1, matcher.matches.length
    assert_equal 1, matcher.matches.fetch(0).search_start
    assert_equal 3, matcher.matches.fetch(0).search_end
  end
end
