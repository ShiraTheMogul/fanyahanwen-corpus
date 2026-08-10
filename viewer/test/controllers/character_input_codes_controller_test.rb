# frozen_string_literal: true

require "test_helper"

class CharacterInputCodesControllerTest < ActionDispatch::IntegrationTest
  test "single ASCII RIME code is searched as a code rather than a Latin character" do
    character = CharacterCodepoint.create!(codepoint: "工".ord, chr: "工")
    CharacterInputCode.create!(
      character_codepoint: character,
      system_id: "test_rime",
      code: "a",
      kind: "input",
      source: "test"
    )

    get character_input_codes_path, params: { system_id: "test_rime", q: "a", limit: 12 }, as: :json

    assert_response :success
    rows = JSON.parse(response.body)
    assert_equal "工", rows.first.fetch("character")
    assert_equal "a", rows.first.fetch("code")
  end

  test "exact match does not return longer prefix codes" do
    exact_character = CharacterCodepoint.create!(codepoint: "工".ord, chr: "工")
    longer_character = CharacterCodepoint.create!(codepoint: "左".ord, chr: "左")

    CharacterInputCode.create!(character_codepoint: exact_character, system_id: "test_rime", code: "a", kind: "input", source: "test")
    CharacterInputCode.create!(character_codepoint: longer_character, system_id: "test_rime", code: "aa", kind: "input", source: "test")

    get character_input_codes_path,
        params: { system_id: "test_rime", q: "a", match: "exact", limit: 12 },
        as: :json

    assert_response :success
    rows = JSON.parse(response.body)
    assert_equal ["工"], rows.map { |row| row.fetch("character") }
  end
end
