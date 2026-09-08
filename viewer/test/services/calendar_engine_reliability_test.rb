# frozen_string_literal: true

require_relative "../test_helper"

class CalendarEngineReliabilityTest < ActiveSupport::TestCase
  test "ISO-like historical dates accept one to four year digits" do
    {
      "1-01-01" => 1,
      "99-12-31" => 99,
      "618-06-18" => 618,
      "999-09-07" => 999,
      "1000-01-01" => 1000
    }.each do |input, expected_year|
      result = CalendarEngine.call(operation: :resolve, value: input)
      assert_equal true, result["resolved"], "expected #{input.inspect} to resolve: #{result.inspect}"
      assert_equal expected_year, result["year"]
    end
  end

  test "BCE input still uses historical numbering" do
    result = CalendarEngine.call(operation: :resolve, value: "1 BCE")
    assert_equal true, result["resolved"]
    assert_equal(-1, result["year"])
  end

  test "signed short historical years work and year zero remains invalid" do
    bce = CalendarEngine.call(operation: :resolve, value: "-1-01-01")
    assert_equal true, bce["resolved"]
    assert_equal(-1, bce["year"])

    zero = CalendarEngine.call(operation: :resolve, value: "0-01-01")
    assert_equal false, zero["resolved"]
    assert_match(/year zero/i, zero["error"])
  end
end
