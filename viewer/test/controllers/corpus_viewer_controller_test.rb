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

end
