# frozen_string_literal: true

require_relative "../test_helper"

class IndexableCharacterTest < ActiveSupport::TestCase
  test "accepts single characters regardless of script" do
    %w[清 〇 〢 𝍠 𝍸 ㇀ ⺀ の コ 한 ᄀ ◜ A].each do |glyph|
      assert CharacterData::IndexableCharacter.single?(glyph), "expected #{glyph.inspect} to be indexable"
      assert CharacterData::IndexableCharacter.codepoint?(glyph.ord)
    end
  end

  test "rejects things the integer codepoint model cannot represent as one character" do
    refute CharacterData::IndexableCharacter.single?("")
    refute CharacterData::IndexableCharacter.single?("ab")
    refute CharacterData::IndexableCharacter.single?("漢\uFE00")
    refute CharacterData::IndexableCharacter.single?(" ")
    refute CharacterData::IndexableCharacter.single?("\n")
  end
end
