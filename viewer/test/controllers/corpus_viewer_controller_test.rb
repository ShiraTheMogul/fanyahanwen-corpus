require_relative "../test_helper"

class CorpusViewerControllerTest < ActiveSupport::TestCase
  test "maps a direct translation file back to its source text" do
    info = CorpusViewerController.new.send(
      :translation_source_info,
      "朝鮮漢文/clean/朝鮮王朝/作品/translation/eng/abc123/page.txt"
    )

    assert_equal "朝鮮漢文/clean/朝鮮王朝/作品/page.txt", info[:source_path]
    assert_equal "abc123", info[:material_id]
  end

  test "does not treat ordinary corpus paths as translations" do
    assert_nil CorpusViewerController.new.send(:translation_source_info, "朝鮮漢文/clean/作品/page.txt")
  end
  test "uses the search body boundary for legacy header fallback" do
    body = CorpusViewerController.new.send(
      :body_from_text,
      "﻿
# PAGE_TITLE: 詩經/關雎
# TIMES: 西周

關關雎鳩，在河之洲。
"
    )

    assert_equal "關關雎鳩，在河之洲。
", body
  end

  test "hidden root entries are not public corpus viewer paths" do
    controller = CorpusViewerController.new

    assert controller.send(:hidden_root_entry?, "scripts")
    assert controller.send(:hidden_root_entry?, "scripts/variant_forms/resources/file.txt")
    assert_not controller.send(:hidden_root_entry?, "中國漢文/clean/作品/file.txt")
  end

  test "corpus reader hides hash-prefixed body lines without changing character offsets" do
    renderer = Class.new do
      include CorpusTextHelper
    end.new

    text = "甲\n# Source: Kanripo\n乙\n"
    rendered = renderer.corpus_text_with_optional_ruby(text, allow_ruby: false).to_s

    assert_equal text.each_char.count, rendered.scan(/data-corpus-idx=/).size
    assert_equal "# Source: Kanripo\n".each_char.count, rendered.scan(/corpus-source-comment/).size
    assert_match(/corpus-source-comment[^>]*hidden[^>]*aria-hidden="true"/, rendered)
    assert_match(/data-corpus-idx="0"[^>]*>甲<\/span>/, rendered)
    assert_match(/>乙<\/span>/, rendered)
  end

  test "corpus viewer standard selector follows CharacterStandards selectable modes" do
    rightbar = Rails.root.join("app", "views", "corpus_viewer", "_rightbar.html.erb").read

    assert_includes rightbar, "CharacterStandards.selectable_modes"
    assert_not_includes rightbar, '[[t("view_options.script.original"), "original"]'
  end
end
