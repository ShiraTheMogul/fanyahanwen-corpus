# frozen_string_literal: true

require_relative "../test_helper"

class DifficultComponentSeederTest < ActiveSupport::TestCase
  setup do
    CharacterProperty.where(source: CharacterData::DifficultComponentSeeder::SOURCE).delete_all
  end

  test "registers palette glyphs in the canonical codepoint table" do
    result = CharacterData::DifficultComponentSeeder.new.seed

    assert_equal 542, result.memberships
    assert_equal 541, result.characters

    %w[一 〢 コ 𦥑 𬺻 䜌].each do |glyph|
      row = CharacterCodepoint.find_by(codepoint: glyph.ord)
      assert row, "expected #{glyph.inspect} in CharacterCodepoint"
      assert_equal glyph, row.chr
    end
  end

  test "stores dictionary lookup memberships separately from IDS search structure" do
    CharacterData::DifficultComponentSeeder.new.seed

    row = CharacterCodepoint.find_by!(codepoint: "𦥑".ord)
    property = CharacterProperty.find_by!(
      character_codepoint: row,
      source: CharacterData::DifficultComponentSeeder::SOURCE,
      field: CharacterData::DifficultComponentSeeder::FIELD
    )

    assert_equal "6 strokes · Slash (撇)", property.value
    assert_equal "Strokes & radicals", FieldLens.group_for(property.field)
    assert_equal "IDS hard-to-input component lookup", FieldLens.label_for(property.field)

    refute CharacterStructureComponent.where(component: "Slash").exists?
    refute CharacterStructureComponent.where(component: "撇").exists?
  end

  test "is idempotent and preserves multiple source memberships" do
    seeder = CharacterData::DifficultComponentSeeder.new
    seeder.seed
    first_count = CharacterProperty.where(source: CharacterData::DifficultComponentSeeder::SOURCE).count
    seeder.seed
    second_count = CharacterProperty.where(source: CharacterData::DifficultComponentSeeder::SOURCE).count

    assert_equal first_count, second_count
    assert_equal 542, second_count

    row = CharacterCodepoint.find_by!(codepoint: "𠫓".ord)
    values = CharacterProperty.where(
      character_codepoint: row,
      source: CharacterData::DifficultComponentSeeder::SOURCE,
      field: CharacterData::DifficultComponentSeeder::FIELD
    ).order(:value).pluck(:value)

    assert_equal ["3 strokes · Horizontal bar (橫)", "4 strokes · Dot (點)"], values
  end
end
