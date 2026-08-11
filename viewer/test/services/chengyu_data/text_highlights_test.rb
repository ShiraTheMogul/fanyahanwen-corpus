# frozen_string_literal: true

require "test_helper"

class ChengyuDataTextHighlightsTest < ActiveSupport::TestCase
  test "confirmed source context overrides the same possible usage without losing either classification" do
    family = Chengyu.create!(source_family_id: "HL-F1", display_form: "一以貫之")
    form = ChengyuForm.create!(
      chengyu: family,
      source_form_id: "HL-FORM1",
      form_text: "一以貫之",
      game_key: "一以貫之",
      is_display_form: true,
      script_class: "han",
      codepoint_length: 4,
      han_character_count: 4,
      is_strict_han: true,
      contains_punctuation: false
    )
    provenance = ChengyuProvenance.create!(
      chengyu: family,
      chengyu_form: form,
      source_provenance_id: "HL-P1",
      site: "enwiktionary",
      pageid: 1,
      page_title: "一以貫之",
      source_title: "Analects"
    )
    occurrence = ChengyuCorpusOccurrence.create!(
      chengyu: family,
      chengyu_form: form,
      chengyu_provenance: provenance,
      document_path: "中國漢文/clean/論語/論語__里仁第四.txt",
      start_offset: 2,
      end_offset: 6,
      matched_text: "一以貫之"
    )

    marks = ChengyuData::TextHighlights.new(
      text: "吾道一以貫之",
      document_path: occurrence.document_path
    ).marks

    assert_includes marks.fetch(2).fetch(:possible), "一以貫之"
    assert_includes marks.fetch(2).fetch(:confirmed), "一以貫之"
    assert_equal occurrence.anchor_id, marks.fetch(2).fetch(:anchor_id)
    assert_includes marks.fetch(5).fetch(:confirmed), "一以貫之"
  end
end
