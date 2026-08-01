require "test_helper"

class CharactersJejueoTest < ActionDispatch::IntegrationTest
  setup do
    PronunciationRegistry.reload!

    @character = CharacterCodepoint.create!(
      chr: "百",
      codepoint: "百".ord
    )

    CharacterProperty.create!(
      character_codepoint: @character,
      source: "Yang, Yang & O’Grady 2020",
      field: "reading.koreanic.jejueo.hangul",
      value: "백"
    )

    CharacterProperty.create!(
      character_codepoint: @character,
      source: "Yang, Yang & O’Grady 2020",
      field: "reading.koreanic.jejueo.source_romanisation",
      value: "beg"
    )
  end

  test "shows Jejueo readings inside the Koreanic pronunciation section" do
    get character_path(@character.chr)

    assert_response :success
    assert_select "details.pronun-section > summary .pronun-section-title", text: "Koreanic"
    assert_select "details.pronun-variety > summary .pronun-section-title", text: "Jejueo"
    assert_select "li.pronun-item", text: /Hangul:\s*백/
    assert_select "li.pronun-item", text: /Source romanisation:\s*beg/
  end
end
