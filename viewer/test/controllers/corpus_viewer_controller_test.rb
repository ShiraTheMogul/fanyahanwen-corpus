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
end
