# frozen_string_literal: true

require "test_helper"

module CharacterQuery
  class AnnotationRendererTest < ActiveSupport::TestCase
    def row(properties: {}, entries: [])
      { char: "鷖", codepoint: 0x9DD6, properties: properties, dictionary_entries: entries }
    end

    test "emits the gloss marker when no citable gloss exists" do
      entry = AnnotationRenderer.new([row]).to_entries.first

      assert_equal AnnotationRenderer::GLOSS_MARKER, entry[:gloss]
      assert entry[:gloss_needs_author],
             "a missing gloss must be flagged for authoring, never invented"
      assert_nil entry[:gloss_source]
    end

    test "uses kDefinition and records its source when present" do
      properties = { "kDefinition" => [{ value: "a kind of gull", source: "Unihan_Readings" }] }
      entry = AnnotationRenderer.new([row(properties: properties)]).to_entries.first

      assert_equal "a kind of gull", entry[:gloss]
      assert_equal "Unihan_Readings", entry[:gloss_source]
      refute entry[:gloss_needs_author]
    end

    test "quotations are attributed to the work they came from" do
      entries = [{ work_title: "集韻", edition_label: nil, definition: "水鳥。鷗也。" }]
      rendered = AnnotationRenderer.new([row(entries: entries)]).to_text

      assert_includes rendered, "《集韻》"
      assert_includes rendered, "水鳥。"
    end

    test "blank dictionary definitions are dropped rather than shown empty" do
      entries = [{ work_title: "說文解字", edition_label: nil, definition: "  " }]
      entry = AnnotationRenderer.new([row(entries: entries)]).to_entries.first

      assert_empty entry[:quotations]
    end

    test "reading comes from the system field, falling back through pinyin fields" do
      properties = { "kMandarin" => [{ value: "yī", source: "Unihan_Readings" }] }
      entry = AnnotationRenderer.new([row(properties: properties)]).to_entries.first

      assert_equal "yī", entry[:reading]
    end
  end
end
