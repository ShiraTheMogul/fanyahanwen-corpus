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

  test "name-like syntax after an authority span can make a person beat a stronger homographic place" do
    %w[曰 謂 問 告 命 使 召].each do |follower|
      annotator = CbdbAutoAnnotator.allocate
      annotator.instance_variable_set(:@chars, "王安#{follower}".each_char.to_a)
      annotator.instance_variable_set(:@prefix_cache, {})
      annotator.instance_variable_set(:@equivalence, IdentityEquivalence.new)
      annotator.instance_variable_set(:@context, {})

      rows = [
        {
          "name_chn" => "王安",
          "kind" => "place",
          "candidate" => candidate("place-1", "place", score: 94)
        },
        {
          "name_chn" => "王安",
          "kind" => "person",
          "candidate" => candidate("person-1", "person", score: 82)
        }
      ]

      resolved = annotator.send(:resolve_overlaps, annotator.send(:build_multi_matches, rows))
      assert_equal 1, resolved.length, follower
      assert_equal "person", resolved.first[:kind], follower
      assert_operator resolved.first[:score], :>, 94, follower
    end
  end

  test "speech bonus does not apply across a sentence boundary" do
    annotator = CbdbAutoAnnotator.allocate
    annotator.instance_variable_set(:@chars, "王安。曰".each_char.to_a)
    annotator.instance_variable_set(:@prefix_cache, {})
    annotator.instance_variable_set(:@equivalence, IdentityEquivalence.new)
    annotator.instance_variable_set(:@context, {})

    rows = [
      {
        "name_chn" => "王安",
        "kind" => "place",
        "candidate" => candidate("place-1", "place", score: 94)
      },
      {
        "name_chn" => "王安",
        "kind" => "person",
        "candidate" => candidate("person-1", "person", score: 82)
      }
    ]

    resolved = annotator.send(:resolve_overlaps, annotator.send(:build_multi_matches, rows))
    assert_equal 1, resolved.length
    assert_equal "place", resolved.first[:kind]
  end

  test "one failing authority source does not disable successful annotations from another source" do
    store = Struct.new(:metadata) do
      def available? = true
      def lookup_available? = true
      def historical_available? = true
      def with_database
        yield Object.new
      end
    end.new({ "cbdb_available" => true, "historical_available" => true })

    annotator = CbdbAutoAnnotator.allocate
    annotator.instance_variable_set(:@text, "孔丘")
    annotator.instance_variable_set(:@chars, "孔丘".each_char.to_a)
    annotator.instance_variable_set(:@metadata, {})
    annotator.instance_variable_set(:@store, store)
    annotator.instance_variable_set(:@equivalence, IdentityEquivalence.new)
    annotator.instance_variable_set(:@prefix_cache, {})
    annotator.define_singleton_method(:temporal_context) { {} }
    annotator.define_singleton_method(:text_prefixes) { ["孔丘"] }
    annotator.define_singleton_method(:cbdb_matches) { |_prefixes| raise "broken CBDB source" }
    annotator.define_singleton_method(:historical_matches) do |_prefixes|
      [{ start: 0, end: 2, text: "孔丘", kind: "person", confidence: "high", score: 100, candidates: [{ id: "x", kind: "person", score: 100, authority_source: "test" }] }]
    end
    annotator.define_singleton_method(:single_character_diviner_matches) { [] }
    annotator.define_singleton_method(:resolve_overlaps) { |matches| matches }
    annotator.define_singleton_method(:public_item) { |match| { "text" => match[:text], "kind" => match[:kind] } }

    result = annotator.call
    assert_equal [{ "text" => "孔丘", "kind" => "person" }], result.items
    assert_equal true, result.authority.fetch("annotation_partial")
    assert_equal ["cbdb"], result.authority.fetch("annotation_failed_sources")
  end

  private

  def candidate(id, kind, score: 90)
    {
      id: id,
      kind: kind,
      score: score,
      primary: true,
      explicit: true,
      derivation: "test",
      authority_source: "cbdb"
    }
  end
end
