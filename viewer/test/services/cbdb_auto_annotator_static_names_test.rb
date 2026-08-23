# frozen_string_literal: true

require_relative "../test_helper"

class CbdbAutoAnnotatorStaticNamesTest < ActiveSupport::TestCase
  UnavailableStore = Struct.new(:metadata) do
    def available? = false
    def lookup_available? = false
    def historical_available? = false
  end

  test "prepended annotator returns the base result type when authority data are unavailable" do
    result = CbdbAutoAnnotator.call(
      text: "孔子曰",
      metadata: { "period" => "春秋" },
      store: UnavailableStore.new({})
    )

    assert_instance_of CbdbAutoAnnotator::Result, result
    assert_equal [], result.items
    assert_equal "春秋", result.context.fetch("period")
  end
end
