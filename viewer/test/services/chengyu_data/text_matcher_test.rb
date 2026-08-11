# frozen_string_literal: true

require "test_helper"

class ChengyuDataTextMatcherTest < ActiveSupport::TestCase
  test "finds a known Chengyu despite punctuation differences and preserves raw offsets" do
    family = Chengyu.create!(source_family_id: "MATCH-F1", display_form: "一言既出，駟馬難追")
    form = ChengyuForm.create!(
      chengyu: family,
      source_form_id: "MATCH-FORM1",
      form_text: "一言既出，駟馬難追",
      game_key: "一言既出駟馬難追",
      is_display_form: true,
      script_class: "han_with_punctuation",
      codepoint_length: 9,
      han_character_count: 8,
      is_strict_han: false,
      contains_punctuation: true
    )

    text = "曰：一言既出、駟馬難追！"
    match = ChengyuData::TextMatcher.new(forms: [form]).matches(text).first

    assert match
    assert_equal family.id, match.chengyu_id
    assert_equal form.id, match.chengyu_form_id
    assert_equal "一言既出、駟馬難追", match.matched_text
    assert_equal 2, match.start_offset
    assert_equal 11, match.end_offset
  end

  test "does not bridge across a line break" do
    family = Chengyu.create!(source_family_id: "MATCH-F2", display_form: "一以貫之")
    form = ChengyuForm.create!(
      chengyu: family,
      source_form_id: "MATCH-FORM2",
      form_text: "一以貫之",
      game_key: "一以貫之",
      is_display_form: true,
      script_class: "han",
      codepoint_length: 4,
      han_character_count: 4,
      is_strict_han: true,
      contains_punctuation: false
    )

    assert_empty ChengyuData::TextMatcher.new(forms: [form]).matches("一以\n貫之")
  end
end
