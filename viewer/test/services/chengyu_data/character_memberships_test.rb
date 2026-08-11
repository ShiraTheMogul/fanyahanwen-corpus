# frozen_string_literal: true

require "test_helper"

class ChengyuDataCharacterMembershipsTest < ActiveSupport::TestCase
  test "returns families whose forms contain the dictionary character" do
    target = CharacterCodepoint.create!(chr: "心", codepoint: "心".ord)
    first = CharacterCodepoint.create!(chr: "一", codepoint: "一".ord)
    last = CharacterCodepoint.create!(chr: "意", codepoint: "意".ord)
    family = Chengyu.create!(source_family_id: "MEM-F1", display_form: "一心一意")
    form = ChengyuForm.create!(
      chengyu: family,
      source_form_id: "MEM-FORM1",
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
    ChengyuFormCharacter.create!(chengyu_form: form, character_codepoint: target, glyph: "心", position: 1)
    ChengyuSense.create!(
      chengyu: family, chengyu_form: form, source_sense_id: "MEM-S1", site: "enwiktionary",
      pageid: 1, page_title: "一心一意", definition_language_tag: "en", plain_definition: "single-mindedly"
    )
    ChengyuAttestation.create!(
      chengyu: family, chengyu_form: form, source_attestation_id: "MEM-A1", site: "enwiktionary",
      pageid: 1, page_title: "一心一意", entry_language_tag: "zh", url: "https://example.test/one"
    )

    memberships = ChengyuData::CharacterMemberships.new(target)
    rows = memberships.rows

    assert_equal 1, memberships.count
    assert_equal 1, rows.length
    assert_equal family, rows.first.chengyu
    assert_equal form, rows.first.matching_form
    assert_equal "single-mindedly", rows.first.sense.plain_definition
    assert_equal ["zh"], rows.first.languages
    assert_includes rows.first.corpus_search_url, "q="
  end
end
