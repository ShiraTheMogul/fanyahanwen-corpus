require_relative "../test_helper"

class CharacterStandardsTest < ActiveSupport::TestCase
  test "all display standards are selectable" do
    assert_equal %i[
      original
      traditional
      simplified
      singapore_1969
      wu_zhao
      shinjitai
      erjian_1
      erjian_2
    ], CharacterStandards.allowed_modes
  end

  test "traditional and simplified conversions use the OpenCC configs" do
    calls = []
    converter = lambda do |text, config|
      calls << [text, config]
      "converted"
    end

    CharacterStandards.stub(:opencc_convert, converter) do
      assert_equal "converted", CharacterStandards.traditional("汉字")
      assert_equal "converted", CharacterStandards.simplified("漢字")
    end

    assert_equal [["汉字", :s2t], ["漢字", :t2s]], calls
  end

  test "Traditional and Simplified conversion falls back to Unihan if OpenCC fails" do
    fallback = lambda do |text, mode|
      "#{mode}:#{text}"
    end

    CharacterStandards.stub(:opencc_convert, nil) do
      CharacterStandards.stub(:unihan_script_convert, fallback) do
        assert_equal "traditional:汉字", CharacterStandards.traditional("汉字")
        assert_equal "simplified:漢字", CharacterStandards.simplified("漢字")
      end
    end
  end

  test "singapore 1969 table contains the checked 502 mappings" do
    assert_equal 502, CharacterStandards.singapore_1969_entries.size
    assert_equal 502, CharacterStandards.singapore_1969_entries.map(&:first).uniq.size
    assert_includes CharacterStandards.singapore_1969_entries, ["錢", "⿰金戋"]
    refute_includes CharacterStandards.singapore_1969_entries.map(&:first), "線"
  end

  test "singapore 1969 converts encoded historical forms" do
    assert_equal "乱耒㘯𭭚𳁖𰗣", CharacterStandards.singapore_1969("亂來場歲覽雜")
  end

  test "singapore 1969 preserves source characters for IDS-only targets" do
    assert_equal "撫無錢麗", CharacterStandards.singapore_1969("撫無錢麗")
  end

  test "shinjitai converts old forms from the bundled OpenCC table" do
    assert_equal "国学会図書館", CharacterStandards.shinjitai("國學會圖書館")
  end

  test "shinjitai honours OpenCC reverse preferences" do
    assert_equal "塩画舗荘闘駆", CharacterStandards.shinjitai("鹽畫鋪莊鬥驅")
  end

  test "bundled OpenCC Shinjitai table is not truncated" do
    assert_equal 408, CharacterStandards.shinjitai_map.size
  end

  test "shinjitai normalises CJK compatibility ideographs like OpenCC t2jp" do
    assert_equal "神", CharacterStandards.shinjitai("神")
  end

  test "wu zhao conversion applies its chosen display mappings character by character" do
    map = { "天" => "𠀑", "月" => "囝", "照" => "曌" }

    CharacterStandards.stub(:zetian_map, map) do
      assert_equal "𠀑囝曌", CharacterStandards.wu_zhao("天月照")
      assert_equal "甲𠀑乙", CharacterStandards.wu_zhao("甲天乙")
    end
  end

  test "erjian modes are recognised independently" do
    assert CharacterStandards.erjian_mode?(:erjian_1)
    assert CharacterStandards.erjian_mode?("erjian-2")
    refute CharacterStandards.erjian_mode?(:simplified)
  end
end
