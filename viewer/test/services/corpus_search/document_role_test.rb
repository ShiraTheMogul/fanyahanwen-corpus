require_relative "../../test_helper"

class CorpusSearchDocumentRoleTest < ActiveSupport::TestCase
  test "classifies canonical and noncanonical path roles" do
    cases = {
      "中國漢文/clean/周朝/詩經.txt" => "canonical",
      "中國漢文/clean/周朝/詩經/variants/毛本.txt" => "textual_variant",
      "中國漢文/clean/隋朝/切韻/reconstruction/藤田拓海/切韻.txt" => "reconstruction",
      "中國漢文/raw/周朝/詩經.txt" => "raw",
      "日本漢文/clean/江戸時代/詩/kanbun/詩.txt" => "derived_reading",
      "中國漢文/clean/周朝/詩經/translation/eng/one/詩經.txt" => "translation",
      "中國漢文/clean/周朝/詩經/annotations/notes.txt" => "annotation",
      "README.txt" => "support"
    }

    cases.each do |path, expected|
      assert_equal expected, CorpusSearch::DocumentRole.classify(path), path
    end
  end

  test "raw role wins over nested special folder names" do
    path = "中國漢文/raw/周朝/variants/translation/source.txt"
    assert_equal "raw", CorpusSearch::DocumentRole.classify(path)
  end

  test "records the canonical work folder for textual witnesses and reconstructions" do
    path = "日本漢文/clean/江戸時代/秋月藩/醉餘口號/variants/版本甲.txt"

    assert_equal "日本漢文/clean/江戸時代/秋月藩/醉餘口號",
      CorpusSearch::DocumentRole.canonical_parent_path(path)

    reconstruction = "中國漢文/clean/隋朝/隋/切韻/reconstruction/藤田拓海/切韻.txt"
    assert_equal "中國漢文/clean/隋朝/隋/切韻",
      CorpusSearch::DocumentRole.canonical_parent_path(reconstruction)
  end
end
