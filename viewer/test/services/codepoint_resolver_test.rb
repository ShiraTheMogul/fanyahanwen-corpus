# frozen_string_literal: true

require "test_helper"

class CodepointResolverTest < ActiveSupport::TestCase
  test "creates a character codepoint with its required chr value" do
    glyph = "清"

    character = CharacterData::CodepointResolver.resolve(codepoint: glyph.ord, glyph: glyph)

    assert_equal glyph.ord, character.codepoint
    assert_equal glyph, character.chr
  end

  test "accepts kana Hangul CJK structural symbols and graphical IDS subjects" do
    %w[の コ 한 ㇀ 〢 ◜].each do |glyph|
      character = CharacterData::CodepointResolver.resolve(codepoint: glyph.ord, glyph: glyph)
      assert_equal glyph, character.chr
    end
  end

  test "returns an existing character codepoint" do
    glyph = "明"
    existing = CharacterCodepoint.create!(codepoint: glyph.ord, chr: glyph)

    resolved = CharacterData::CodepointResolver.resolve(codepoint: glyph.ord, glyph: glyph)

    assert_equal existing.id, resolved.id
  end

  test "rejects a mismatched glyph" do
    assert_raises(ArgumentError) do
      CharacterData::CodepointResolver.resolve(codepoint: "清".ord, glyph: "明")
    end
  end

  test "rejects multi-codepoint grapheme sequences because the schema stores one codepoint" do
    assert_raises(ArgumentError) do
      CharacterData::CodepointResolver.resolve(codepoint: "漢".ord, glyph: "漢\uFE00")
    end
  end
end
