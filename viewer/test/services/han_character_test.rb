# frozen_string_literal: true

require_relative "../test_helper"

class HanCharacterTest < ActiveSupport::TestCase
  test "covers the Unicode 17 Han script repertoire used by the project" do
    accepted = [
      0x2E80, 0x2EF3,   # CJK radicals
      0x2F00, 0x2FD5,   # Kangxi radicals
      0x3005, 0x3007,   # iteration mark / ideographic zero
      0x3021, 0x3029,   # 〡..〩 Hangzhou/Suzhou numerals
      0x3038, 0x303B,   # larger numerals / vertical iteration mark
      0x2B73F, 0x2CEAD, # filled extension tails
      0x2EBF0, 0x2EE5D, # Extension I
      0x30000, 0x3134A, # Extension G
      0x31350, 0x33479  # Extensions H/J
    ]

    accepted.each do |codepoint|
      assert CharacterData::HanCharacter.codepoint?(codepoint), "expected U+#{codepoint.to_s(16).upcase} to be Han"
    end
  end

  test "keeps Unicode Script=Common CJK strokes out of the Han property without blocking indexing" do
    refute CharacterData::HanCharacter.single?("㇀")
    assert CharacterData::IndexableCharacter.single?("㇀")
  end

  test "keeps kana and Hangul distinct in classification while allowing character pages" do
    %w[の コ 한 ᄀ].each do |glyph|
      refute CharacterData::HanCharacter.single?(glyph)
      assert CharacterData::IndexableCharacter.single?(glyph)
    end
  end

  test "includes the project seal-script range separately" do
    assert CharacterData::HanCharacter.codepoint?(0x3D000)
    refute CharacterData::HanCharacter.codepoint?(0x3D000, include_project: false)
  end

  test "does not overrun assigned Unicode Han endpoints" do
    [0x2EF4, 0x2FD6, 0xFA6E, 0xFA6F, 0x2FA1E, 0x2FA1F, 0x3347A].each do |codepoint|
      refute CharacterData::HanCharacter.codepoint?(codepoint), "expected U+#{codepoint.to_s(16).upcase} outside Unicode Han"
    end
  end
end
