require_relative "../test_helper"

class EraCalendarConverterInvariantsTest < ActiveSupport::TestCase
  setup do
    # These arithmetic helpers do not depend on authority data. Allocating the
    # converter directly keeps the tests focused on the calendar invariants.
    @converter = EraCalendarConverter.allocate
  end

  test "era-year arithmetic skips the nonexistent historical year zero" do
    assert_equal 1, @converter.send(:era_year_number, -1, -1)
    assert_equal 2, @converter.send(:era_year_number, -1, 1)
    assert_equal 3, @converter.send(:era_year_number, -1, 2)
  end

  test "year one is rendered with 元 and later years use Han numerals" do
    assert_equal "建元元年", @converter.send(:era_expression, "建元", 1, -140, nil)
    assert_equal "建元十一年", @converter.send(:era_expression, "建元", 11, -130, nil)
    assert_equal "建元一百零一年", @converter.send(:era_expression, "建元", 101, -40, nil)
  end

  test "Taiping sexagenary branch substitutions remain confined to Taiping output" do
    ordinary = @converter.send(:sexagenary_for, 1853, taiping: false)
    taiping = @converter.send(:sexagenary_for, 1853, taiping: true)

    assert_equal "癸丑", ordinary
    assert_equal "癸好", taiping
    assert_equal "太平天國癸好三年",
      @converter.send(:era_expression, "太平天國", 3, 1853, "china-taiping-tianguo-main")
  end
end
