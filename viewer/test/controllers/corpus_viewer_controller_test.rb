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
  test "uses the search body boundary while preserving viewer metadata labels" do
    meta, body = CorpusViewerController.new.send(
      :split_corpus_front_matter,
      "\uFEFF\n# PAGE_TITLE: 詩經/關雎\n# TIMES: 西周\n\n關關雎鳩，在河之洲。\n"
    )

    assert_includes meta, ["Page title", "詩經/關雎"]
    assert_includes meta, ["Time and/or Location", "西周"]
    assert_equal "關關雎鳩，在河之洲。\n", body
  end

end
