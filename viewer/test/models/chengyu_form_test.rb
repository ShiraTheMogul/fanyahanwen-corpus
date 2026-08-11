# frozen_string_literal: true

require "test_helper"

class ChengyuFormTest < ActiveSupport::TestCase
  test "standard and hard pools keep length policy out of the Chengyu identity" do
    first = CharacterCodepoint.create!(chr: "一", codepoint: "一".ord)
    last = CharacterCodepoint.create!(chr: "意", codepoint: "意".ord)

    standard_family = Chengyu.create!(source_family_id: "TEST-F1", display_form: "一心一意")
    standard = ChengyuForm.create!(
      chengyu: standard_family,
      source_form_id: "TEST-FORM1",
      form_text: "一心一意",
      game_key: "一心一意",
      is_display_form: true,
      script_class: "han",
      codepoint_length: 4,
      han_character_count: 4,
      is_strict_han: true,
      contains_punctuation: false,
      first_character_codepoint: first,
      last_character_codepoint: last
    )

    hard_family = Chengyu.create!(source_family_id: "TEST-F2", display_form: "一言既出，駟馬難追")
    hard = ChengyuForm.create!(
      chengyu: hard_family,
      source_form_id: "TEST-FORM2",
      form_text: "一言既出，駟馬難追",
      game_key: "一言既出駟馬難追",
      is_display_form: true,
      script_class: "han_with_punctuation",
      codepoint_length: 9,
      han_character_count: 8,
      is_strict_han: false,
      contains_punctuation: true,
      first_character_codepoint: first,
      last_character_codepoint: CharacterCodepoint.create!(chr: "追", codepoint: "追".ord)
    )

    assert_includes ChengyuForm.standard_game_pool, standard
    refute_includes ChengyuForm.standard_game_pool, hard
    assert_includes ChengyuForm.hard_game_pool, standard
    assert_includes ChengyuForm.hard_game_pool, hard
    assert hard.compound?
    refute standard.compound?
  end
end
