# frozen_string_literal: true

require_relative "../test_helper"

class HistoricalDateResolverMinguoTest < ActiveSupport::TestCase
  test "resolves Minguo calendar dates without an authority cache" do
    unavailable_store = Object.new
    unavailable_store.define_singleton_method(:available?) { false }
    resolver = HistoricalDateResolver.new(store: unavailable_store)

    cases = {
      "中華民國元年" => 1912,
      "中华民国2年" => 1913,
      "民國110年6月" => 2021,
      "民国一百一十五年八月二十六日" => 2026
    }

    cases.each do |label, expected_year|
      resolution = resolver.resolve(metadata: { "corpus_root" => "中國漢文", "date_label" => label })
      assert resolution, "expected #{label.inspect} to resolve"
      assert_equal expected_year, resolution.year_start, label
      assert_equal expected_year, resolution.year_end, label
      assert_equal "date_label_minguo", resolution.source, label
      assert_equal "explicit_label", resolution.confidence, label
      assert_equal label, resolution.date_label, label
      assert_nil resolution.authority_kind, label
    end
  end

  test "rejects invalid Minguo month and day values" do
    unavailable_store = Object.new
    unavailable_store.define_singleton_method(:available?) { false }
    resolver = HistoricalDateResolver.new(store: unavailable_store)

    assert_nil resolver.resolve(metadata: { "date_label" => "民國110年13月" })
    assert_nil resolver.resolve(metadata: { "date_label" => "民國110年6月32日" })
  end
end
