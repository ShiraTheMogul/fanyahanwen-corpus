# frozen_string_literal: true

require_relative "../test_helper"
require "set"

class CbdbAutoAnnotatorKindResolutionTest < ActiveSupport::TestCase
  IdentityEquivalence = Struct.new(:unused) do
    def forms_for(character)
      Set[character]
    end

    def equivalent?(left, right)
      left == right
    end
  end

  test "homographic entity kinds remain separate until overlap resolution" do
    annotator = CbdbAutoAnnotator.allocate
    annotator.instance_variable_set(:@chars, "王安".each_char.to_a)
    annotator.instance_variable_set(:@prefix_cache, {})
    annotator.instance_variable_set(:@equivalence, IdentityEquivalence.new)

    rows = [
      {
        "name_chn" => "王安",
        "kind" => "place",
        "candidate" => candidate("place-1", "place")
      },
      {
        "name_chn" => "王安",
        "kind" => "person",
        "candidate" => candidate("person-1", "person")
      }
    ]

    matches = annotator.send(:build_multi_matches, rows)
    assert_equal %w[person place], matches.map { |match| match[:kind] }.sort_by { |kind| kind == "person" ? 0 : 1 }

    resolved = annotator.send(:resolve_overlaps, matches)
    assert_equal 1, resolved.length
    assert_equal "person", resolved.first[:kind]
    assert_equal ["person-1"], resolved.first[:candidates].map { |candidate| candidate[:id] }
  end

  private

  def candidate(id, kind)
    {
      id: id,
      kind: kind,
      score: 90,
      primary: true,
      explicit: true,
      derivation: "test",
      authority_source: "cbdb"
    }
  end
end
