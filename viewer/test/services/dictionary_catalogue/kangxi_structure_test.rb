# frozen_string_literal: true

require "test_helper"

class DictionaryCatalogue::KangxiStructureTest < ActiveSupport::TestCase
  test "parses ordinary kRSUnicode token" do
    membership = DictionaryCatalogue::KangxiStructure.parse_token("85.4")

    assert_equal 85, membership.radical_number
    assert_equal 4, membership.additional_strokes
    assert_equal "85.4", membership.raw_token
  end

  test "accepts apostrophe variant in kRSUnicode token" do
    membership = DictionaryCatalogue::KangxiStructure.parse_token("162'.3")

    assert_equal 162, membership.radical_number
    assert_equal 3, membership.additional_strokes
  end

  test "rejects malformed radical token" do
    assert_nil DictionaryCatalogue::KangxiStructure.parse_token("85")
    assert_nil DictionaryCatalogue::KangxiStructure.parse_token("radical.4")
    assert_nil DictionaryCatalogue::KangxiStructure.parse_token("")
  end
end
