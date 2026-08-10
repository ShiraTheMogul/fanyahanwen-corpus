# frozen_string_literal: true

require "test_helper"

class FieldLensCharacterDataTest < ActiveSupport::TestCase
  setup do
    @character = CharacterCodepoint.create!(chr: "𠀀", codepoint: 0x20000)
  end

  test "projects RIME input codes into the Input group in stable order" do
    old_cangjie = CharacterProperty.new(
      character_codepoint: @character,
      field: "kCangjie",
      value: "M",
      source: "Unihan_DictionaryLikeData"
    )

    CharacterInputCode.create!(
      character_codepoint: @character,
      system_id: "moran",
      code: "ab",
      kind: "auxiliary",
      source: "rimeinn/rime-moran"
    )
    CharacterInputCode.create!(
      character_codepoint: @character,
      system_id: "wubi86",
      code: "ggll",
      kind: "input",
      source: "rime/rime-wubi"
    )
    CharacterInputCode.create!(
      character_codepoint: @character,
      system_id: "cangjie5",
      code: "mlll",
      kind: "input",
      source: "rime/rime-cangjie"
    )

    groups = FieldLens.with_character_data([["Input", [old_cangjie]]], @character).to_h

    assert_equal %w[kCangjie rime_cangjie5 rime_wubi86 rime_moran], groups.fetch("Input").map(&:field)
    assert_equal "第三代倉頡輸入法 Cāngjié 3 input method", FieldLens.label_for("kCangjie")
    assert_equal "第五代倉頡輸入法 Cāngjié 5 input method", FieldLens.label_for("rime_cangjie5")
    assert_equal "五筆字型 86 Wubi 86 input method", FieldLens.label_for("rime_wubi86")
    assert_equal "RIME-Moran input (auxiliary code)", FieldLens.label_for("rime_moran")
  end

  test "groups repeated IDS levels by clean deconstruction and keeps annotations separate" do
    create_structure(
      level: "lv0",
      expression: "⿰氵青",
      metadata: {
        "variants" => [
          { "raw_expression" => "⿰氵青(T)", "annotations" => [], "indicators" => ["T"] }
        ]
      }
    )
    create_structure(
      level: "lv1",
      expression: "⿰氵青",
      metadata: {
        "variants" => [
          { "raw_expression" => "⿰氵青(qs)", "annotations" => ["qs"], "indicators" => [] }
        ]
      }
    )
    create_structure(level: "lv2", expression: "⿱水靑", metadata: { "variants" => [] })

    rows = FieldLens.ids_deconstructions_for(@character)
    horizontal = rows.find { |row| row[:expression] == "⿰氵青" }

    assert_equal 2, rows.length
    assert_equal %w[lv0 lv1], horizontal.fetch(:levels)
    assert_equal %w[T qs], horizontal.fetch(:source_annotations)
    assert_equal "⿰氵青", horizontal.fetch(:normalized_expression)
    refute_includes horizontal.fetch(:expression), "qs"
    refute_includes horizontal.fetch(:expression), "T"
  end

  private

  def create_structure(level:, expression:, metadata:)
    CharacterStructure.create!(
      character_codepoint: @character,
      system: "ids",
      expression: expression,
      normalized_expression: expression,
      source: "yi-bai/ids",
      source_level: level,
      source_version: "test",
      glyph_region: "",
      metadata: metadata
    )
  end
end
