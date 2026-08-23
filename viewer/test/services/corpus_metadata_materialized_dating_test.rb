# frozen_string_literal: true

require_relative "../test_helper"

class CorpusMetadataMaterializedDatingTest < ActiveSupport::TestCase
  class FakeMetadataStore
    prepend CorpusMetadataMaterializedDating

    def initialize(metadata, base_result: nil)
      @metadata = metadata
      @base_result = base_result || { "year_start" => nil, "year_end" => nil, "date_text" => "" }
    end

    def search_metadata_for_path(_path)
      @base_result.dup
    end

    def display_entries_for_path(_path)
      []
    end

    def document_metadata_for_path(_path)
      @metadata
    end
  end

  test "materialized date provides exact search bounds" do
    result = FakeMetadataStore.new({ "date" => "1544年" }).search_metadata_for_path("x")
    assert_equal 1544, result["year_start"]
    assert_equal 1544, result["year_end"]
    assert_equal "1544年", result["date_text"]
  end

  test "materialized ca provides approximate search bounds" do
    result = FakeMetadataStore.new({ "ca" => "1409–1469年" }).search_metadata_for_path("x")
    assert_equal 1409, result["year_start"]
    assert_equal 1469, result["year_end"]
    assert_equal "ca. 1409–1469年", result["date_text"]
  end

  test "BCE and crossing-era ca forms remain searchable" do
    bce = FakeMetadataStore.new({ "ca" => "前770–前476年" }).search_metadata_for_path("x")
    assert_equal(-770, bce["year_start"])
    assert_equal(-476, bce["year_end"])

    crossing = FakeMetadataStore.new({ "ca" => "前206–220年" }).search_metadata_for_path("x")
    assert_equal(-206, crossing["year_start"])
    assert_equal 220, crossing["year_end"]
  end

  test "existing numeric bounds win over materialized ca" do
    store = FakeMetadataStore.new(
      { "ca" => "1409–1469年" },
      base_result: { "year_start" => 1500, "year_end" => 1500, "date_text" => "1500年" }
    )

    result = store.search_metadata_for_path("x")
    assert_equal 1500, result["year_start"]
    assert_equal 1500, result["year_end"]
  end
end
