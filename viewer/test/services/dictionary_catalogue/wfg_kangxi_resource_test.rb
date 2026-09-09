# frozen_string_literal: true

require_relative "../../test_helper"

class WfgKangxiResourceTest < ActiveSupport::TestCase
  test "bundled WFG resource passes byte and count validation" do
    resource = DictionaryCatalogue::WfgKangxiResource
    assert resource.available?
    metadata = resource.metadata_hash
    assert_equal "47043", metadata.fetch("occurrence_count")
    assert_equal "247", metadata.fetch("redirect_count")
    assert_equal "47853", metadata.fetch("resource_count")
  end

  test "known WFG digital key correction retains the source image" do
    resource = DictionaryCatalogue::WfgKangxiResource
    row = resource.occurrence(24_335)
    assert_equal "𦛢", row.fetch("headword")
    assert_equal "腘", row.fetch("source_headword")
    assert resource.resource_exists?(row.fetch("image_key"))
    assert_match(/\Adata:image\/gif;base64,/, resource.image_data_uri(row.fetch("image_key")))
  end

  test "WFG empty headword field falls back to its confirmed record key" do
    row = DictionaryCatalogue::WfgKangxiResource.occurrence(10_286)
    assert_equal "㩮", row.fetch("headword")
    assert_equal "㩮", row.fetch("source_headword")
    assert_equal '\\3A6E.gif', row.fetch("image_key")
  end
  test "supplement stroke metadata is usable while retaining WFG raw values" do
    row = DictionaryCatalogue::WfgKangxiResource.occurrence(41_088)
    assert_equal "㠏", row.fetch("headword")
    assert_equal 11, row.fetch("additional_strokes")
    assert_equal 14, row.fetch("total_strokes")
    assert_equal "山部11", row.fetch("additional_strokes_raw")
    assert_equal "3", row.fetch("total_strokes_raw")
  end

end
