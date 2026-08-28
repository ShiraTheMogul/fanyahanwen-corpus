# frozen_string_literal: true

require_relative "../test_helper"

class CalendarEngineTest < ActiveSupport::TestCase
  test "resolves deterministic named year systems with one historical-year arithmetic" do
    minguo = CalendarEngine.call(operation: :resolve, value: "民國一百一十五年八月二十六日")
    assert minguo["resolved"]
    assert_equal 2026, minguo["year"]
    assert_equal 8, minguo["month"]
    assert_equal 26, minguo["day"]
    assert_equal "day", minguo["precision"]
    assert_equal "minguo", minguo["source_system"]

    juche = CalendarEngine.call(operation: :resolve, value: "主體2500年")
    assert_equal 4411, juche["year"]

    buddhist = CalendarEngine.call(operation: :resolve, value: "佛曆2569年")
    assert_equal 2026, buddhist["year"]
    assert_equal(-543, CalendarEngine.call(operation: :resolve, value: "佛曆元年")["year"])
    assert_equal(-1, CalendarEngine.call(operation: :resolve, value: "佛曆543年")["year"])
    assert_equal 1, CalendarEngine.call(operation: :resolve, value: "佛曆544年")["year"]
  end

  test "does not silently choose between Huangdi epoch conventions" do
    result = CalendarEngine.call(operation: :resolve, value: "黃帝紀年四千七百二十四年")
    refute result["resolved"]
    assert result["ambiguous"]
    assert_equal [2026, 2027], result.fetch("candidates").map { |candidate| candidate.fetch("year") }.sort

    explicit = CalendarEngine.call(
      operation: :resolve,
      value: "黃帝紀年四千七百二十四年",
      system: "huangdi_2698"
    )
    assert explicit["resolved"]
    assert_equal 2026, explicit["year"]
  end

  test "represents 2026 in all configured year systems from the same registry" do
    result = CalendarEngine.call(operation: :represent, value: 2026)
    rows = result.fetch("year_systems").index_by { |row| row.fetch("key") }

    assert_equal 115, rows.fetch("minguo").fetch("year_number")
    assert_equal 115, rows.fetch("juche").fetch("year_number")
    assert_equal 2569, rows.fetch("buddhist_era_common").fetch("year_number")
    assert_equal 4723, rows.fetch("huangdi_2697").fetch("year_number")
    assert_equal 4724, rows.fetch("huangdi_2698").fetch("year_number")
    assert_equal 4182, rows.fetch("tangyao").fetch("year_number")
    assert_equal 2867, rows.fetch("gonghe").fetch("year_number")
    assert_equal 2577, rows.fetch("confucius").fetch("year_number")
    assert_equal 2247, rows.fetch("unity").fetch("year_number")
    assert_equal "丙午", result["sexagenary_year"]
    assert_equal "柔兆敦牂", result["erya_year"]
  end

  test "keeps sexagenary cycle identity separate from absolute dating" do
    shang = CalendarEngine.call(operation: :lookup, value: "庚戌", context: { cycle_scope: "shang_day" })
    assert shang["resolved"]
    assert_equal 47, shang["cycle_number"]
    assert_equal "day", shang["cycle_scope"]
    assert_equal "合集37986", shang.dig("source", "label")
    assert_nil shang["year"]
  end

  test "recognises Erya nomenclature without inventing an absolute year" do
    year = CalendarEngine.call(operation: :lookup, value: "閼逢攝提格")
    assert_equal "甲寅", year["sexagenary"]
    assert_equal 51, year["cycle_number"]
    assert_nil year["year"]

    month = CalendarEngine.call(operation: :lookup, value: "畢陬")
    assert_equal "甲", month["month_stem"]
    assert_equal 1, month["month"]

    isolated = CalendarEngine.call(operation: :lookup, value: "陽")
    refute isolated["resolved"]

    contextual = CalendarEngine.call(operation: :lookup, value: "陽", context: { nomenclature: "erya_month" })
    assert contextual["resolved"]
    assert_equal 10, contextual["month"]
  end

  test "extracts a leading date for non-Ruby consumers without exposing calendar syntax" do
    minguo = CalendarEngine.call(operation: :resolve_prefix, value: "民國一百一十五年八月二十六日中央日報")
    assert minguo["resolved"]
    assert_equal 2026, minguo["year"]
    assert_equal 8, minguo["month"]
    assert_equal 26, minguo["day"]
    assert_equal "民國一百一十五年八月二十六日", minguo["consumed"]
    assert_equal "中央日報", minguo["rest"]

    gregorian = CalendarEngine.call(operation: :resolve_prefix, value: "2026年8月28日刊")
    assert gregorian["resolved"]
    assert_equal "2026年8月28日", gregorian["consumed"]
    assert_equal "刊", gregorian["rest"]

    cycle = CalendarEngine.call(operation: :resolve_prefix, value: "庚戌卜")
    refute cycle["resolved"]
  end

  test "rejects impossible Gregorian fields before consumers can assign them" do
    refute CalendarEngine.call(operation: :resolve, value: "民國110年13月")["resolved"]
    refute CalendarEngine.call(operation: :resolve, value: "民國110年6月32日")["resolved"]
    refute CalendarEngine.call(operation: :resolve, value: "2026年2月29日")["resolved"]
  end

  test "keeps the established regnal converter behind the same public gateway" do
    delegated = { "direction" => "absolute_to_era", "absolute_year" => 1853, "matches" => [] }
    EraCalendarConverter.stub(:convert, delegated) do
      result = CalendarEngine.call(
        operation: :era_convert,
        value: "1853",
        direction: "absolute_to_era",
        country: "China"
      )
      assert_equal "era_convert", result["operation"]
      assert_equal 1853, result["absolute_year"]
    end
  end

  test "uses when_exe for calendar-frame conversion" do
    result = CalendarEngine.call(operation: :convert, value: "2026-08-28", from: "gregorian", to: "julian")
    assert result["resolved"], result["error"]
    assert_equal "when_exe", result["backend"]
    assert_equal 2026, result.dig("result", "year")
    assert_equal 8, result.dig("result", "month")
    assert_equal 15, result.dig("result", "day")

    # 1900-02-29 is valid in the Julian calendar but invalid Gregorian. The
    # source calendar backend must validate its own coordinates.
    julian_leap = CalendarEngine.call(operation: :convert, value: "1900-02-29", from: "julian", to: "gregorian")
    assert julian_leap["resolved"], julian_leap["error"]
    assert_equal [1900, 3, 13], %w[year month day].map { |key| julian_leap.dig("result", key) }
  end
end
