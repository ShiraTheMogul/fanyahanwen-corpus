# frozen_string_literal: true

require "test_helper"

class HistoricalMeasurementsTest < ActiveSupport::TestCase
  test "every arithmetic claim and standard has source coverage" do
    assert_empty HistoricalMeasurements.audit_errors
  end

  test "catalogue callers cannot mutate the shared registry" do
    first = HistoricalMeasurements.catalogue
    second = HistoricalMeasurements.catalogue

    first.fetch("units").fetch("chi")["han"] = "改"

    assert_equal "尺", second.fetch("units").fetch("chi").fetch("han")
    assert_equal "尺", HistoricalMeasurements.catalogue.fetch("units").fetch("chi").fetch("han")
  end

  test "1915 construction chi and kuping liang retain their statutory magnitudes" do
    catalogue = HistoricalMeasurements.catalogue
    length = catalogue.fetch("standards").find { |standard| standard.fetch("id") == "roc_1915_length" }
    mass = catalogue.fetch("standards").find { |standard| standard.fetch("id") == "roc_1915_mass" }

    assert_in_delta 0.32, length.fetch("base_si"), 1e-12
    assert_in_delta 0.037301, mass.fetch("base_si"), 1e-12
  end

  test "1930 market system keeps exact metric anchors" do
    catalogue = HistoricalMeasurements.catalogue
    length = catalogue.fetch("standards").find { |standard| standard.fetch("id") == "roc_1930_length" }
    mass = catalogue.fetch("standards").find { |standard| standard.fetch("id") == "roc_1930_mass" }
    capacity = catalogue.fetch("standards").find { |standard| standard.fetch("id") == "roc_1930_capacity" }

    assert_in_delta Rational(1, 3).to_f, length.fetch("base_si"), 1e-12
    assert_in_delta 0.03125, mass.fetch("base_si"), 1e-12
    assert_in_delta 1.0, capacity.fetch("base_si"), 1e-12
  end

  test "disputed ren definitions remain separate source claims" do
    claims = HistoricalMeasurements.catalogue.fetch("units").fetch("ren").fetch("claims")
    factors = claims.filter_map { |claim| claim["factor"] }.sort

    assert_equal [4, 5.6, 7, 8], factors
  end

  test "same graph can remain distinct across dimensions" do
    units = HistoricalMeasurements.catalogue.fetch("units")

    assert_equal "mass", units.fetch("shi_mass").fetch("category")
    assert_equal "capacity", units.fetch("shi_capacity").fetch("category")
    assert_equal "length", units.fetch("miao_length").fetch("category")
    assert_equal "time", units.fetch("second").fetch("category")
  end
  test "common Chinese units retain Cantonese and Taiwanese parser romanisations" do
    units = HistoricalMeasurements.catalogue.fetch("units")

    assert_equal "cek3", units.fetch("chi").fetch("romanisations").fetch("jyutping")
    assert_equal "tshioh", units.fetch("chi").fetch("romanisations").fetch("tailo")
    assert_equal "chhioh", units.fetch("chi").fetch("romanisations").fetch("poj")
    assert_equal "cyun3", units.fetch("cun").fetch("romanisations").fetch("jyutping")
    assert_equal "tshùn", units.fetch("cun").fetch("romanisations").fetch("tailo")
  end

end
