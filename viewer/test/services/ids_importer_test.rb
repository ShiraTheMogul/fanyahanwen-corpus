# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class IdsImporterTest < ActiveSupport::TestCase
  test "defines all three pinned Yi Bai IDS levels" do
    assert_equal %w[lv0 lv1 lv2], Ids::Importer::LEVELS

    Ids::Importer::LEVELS.each do |level|
      assert_equal(
        "https://raw.githubusercontent.com/yi-bai/ids/#{Ids::Importer::DEFAULT_VERSION}/ids_#{level}.txt",
        Ids::Importer::DEFAULT_URLS.fetch(level)
      )
    end
  end

  test "registers non-Han subjects and literal IDS leaves in the canonical codepoint table" do
    io = StringIO.new("⺌\t⿰丶リ\nの\t#(kana)\n")

    result = Ids::Importer.new(source: "test/ids", source_version: "test").import(level: "lv1", io: io)

    assert_equal 4, result.characters
    %w[⺌ 丶 リ の].each do |glyph|
      assert CharacterCodepoint.exists?(codepoint: glyph.ord, chr: glyph), "expected #{glyph.inspect} in CharacterCodepoint"
    end
  end

  test "stores source annotations only in metadata, never in searchable IDS fields" do
    raw = "⿱⿴𦥑与qs𬺢(g.n,gpn)"
    functional = "⿱⿴𦥑与𬺢"
    io = StringIO.new("譽\t#{raw}\n")

    result = Ids::Importer.new(source: "test/ids", source_version: "test").import(level: "lv2", io: io)

    assert result.clean?
    structure = CharacterStructure.find_by!(
      character_codepoint: CharacterCodepoint.find_by!(codepoint: "譽".ord),
      system: "ids",
      source: "test/ids",
      source_level: "lv2"
    )

    assert_equal functional, structure.expression
    assert_equal functional, structure.normalized_expression
    refute_includes structure.expression, "qs"
    refute_includes structure.normalized_expression, "qs"
    refute structure.components.where(component: ["q", "s"]).exists?

    variant = structure.metadata.fetch("variants").fetch(0)
    assert_equal raw, variant.fetch("raw_expression")
    assert_equal ["qs"], variant.fetch("annotations")
    assert_equal ["g.n", "gpn"], variant.fetch("indicators")
  end

  test "strict import rolls back when any yi-bai candidate is not understood" do
    before_structures = CharacterStructure.count
    before_components = CharacterStructureComponent.count
    io = StringIO.new("明\t⿰日月\n清\t⿰氵\n")

    error = assert_raises(Ids::Importer::ImportError) do
      Ids::Importer.new(source: "test/ids", source_version: "test").import(level: "lv1", io: io)
    end

    assert_match(/candidate_errors=1/, error.message)
    assert_equal before_structures, CharacterStructure.count
    assert_equal before_components, CharacterStructureComponent.count
  end
end
