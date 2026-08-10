# frozen_string_literal: true

require_relative "../test_helper"

class CoreRepertoireSeederTest < ActiveSupport::TestCase
  test "contains the requested numeral repertoires exactly" do
    suzhou = CharacterData::CoreRepertoireSeeder.codepoints_for(:suzhou_numerals)
    rods = CharacterData::CoreRepertoireSeeder.codepoints_for(:counting_rod_numerals)
    tallies = CharacterData::CoreRepertoireSeeder.codepoints_for(:tally_marks)

    assert_equal [0x3007, *(0x3021..0x3029), *(0x3038..0x303A)], suzhou
    assert_equal (0x1D360..0x1D371).to_a, rods
    assert_equal (0x1D372..0x1D378).to_a, tallies
  end

  test "includes modern and historical Kana and Hangul" do
    kana = CharacterData::CoreRepertoireSeeder.codepoints_for(:kana)
    hangul = CharacterData::CoreRepertoireSeeder.codepoints_for(:hangul)

    %w[の コ ゟ ヿ].each { |glyph| assert_includes kana, glyph.ord }
    [0x1B001, 0x1B11F, 0x1AFF0, 0x1B167].each { |codepoint| assert_includes kana, codepoint }

    %w[한 ᄀ ㆍ].each { |glyph| assert_includes hangul, glyph.ord }
    [0xA960, 0xD7B0, 0xD7FB, 0xFFA0].each { |codepoint| assert_includes hangul, codepoint }
  end

  test "seeds into CharacterCodepoint idempotently" do
    codepoints = CharacterData::CoreRepertoireSeeder.codepoints_for(:suzhou_numerals)
    CharacterCodepoint.where(codepoint: codepoints).delete_all

    first = CharacterData::CoreRepertoireSeeder.new.seed(repertoires: [:suzhou_numerals])
    second = CharacterData::CoreRepertoireSeeder.new.seed(repertoires: [:suzhou_numerals])

    assert_equal codepoints.length, first.created
    assert_equal 0, second.created
    assert_equal codepoints.length, second.existing
    assert_equal codepoints.length, CharacterCodepoint.where(codepoint: codepoints).count
  end
end