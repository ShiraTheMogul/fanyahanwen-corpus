# frozen_string_literal: true

require_relative "../test_helper"

class CharacterStandardsReliabilityTest < ActiveSupport::TestCase
  test "OpenCC nil result propagates instead of becoming a partial Unihan conversion" do
    CharacterStandards.stub(:opencc_convert, nil) do
      error = assert_raises(CharacterStandards::ConversionUnavailable) do
        CharacterStandards.traditional("区动战这乱")
      end
      assert_match(/OpenCC could not run the s2t conversion/, error.message)
    end
  end

  test "regional Traditional pass may retain a successful Standard Traditional base" do
    source = "區動戰這亂"
    CharacterStandards.stub(:traditional, source) do
      CharacterStandards.stub(:opencc_convert, nil) do
        assert_equal source, CharacterStandards.hong_kong_traditional("区动战这乱")
        assert_equal source, CharacterStandards.taiwan_traditional("区动战这乱")
      end
    end
  end

  test "top-level named conversion does not swallow OpenCC unavailability" do
    failure = CharacterStandards::ConversionUnavailable.new("OpenCC unavailable")
    CharacterStandards.stub(:traditional, ->(*) { raise failure }) do
      error = assert_raises(CharacterStandards::ConversionUnavailable) do
        CharacterStandards.convert("区", :traditional)
      end
      assert_equal "OpenCC unavailable", error.message
    end
  end

  test "Mainland Traditional retains Standard Traditional if only its regional pass fails" do
    source = "區動戰這亂"
    failure = CharacterStandards::ConversionUnavailable.new("t2gov unavailable")

    CharacterStandards.stub(:traditional, source) do
      CharacterStandards.stub(:opencc_convert_file, ->(*) { raise failure }) do
        assert_equal source, CharacterStandards.mainland_traditional("区动战这乱")
      end
    end
  end

  test "Mainland Traditional does not hide failure of the Standard Traditional stage" do
    failure = CharacterStandards::ConversionUnavailable.new("s2t unavailable")
    CharacterStandards.stub(:traditional, ->(*) { raise failure }) do
      error = assert_raises(CharacterStandards::ConversionUnavailable) do
        CharacterStandards.mainland_traditional("区动战这乱")
      end
      assert_equal "s2t unavailable", error.message
    end
  end

  test "Wu Zhao applies special graphs after Standard Traditional" do
    CharacterStandards.stub(:traditional, "甚麼照") do
      CharacterStandards.stub(:zetian_map, { "照" => "曌" }) do
        assert_equal "甚麼曌", CharacterStandards.wu_zhao("甚么照")
      end
    end
  end

  test "real Standard Traditional covers the reported OpenCC regression characters" do
    assert_equal "區動戰這亂", CharacterStandards.traditional("区动战这乱")
  end
  test "OpenCC named conversions try the documented json configuration filename" do
    candidates = CharacterStandards.opencc_config_candidates(:t2s)
    assert_includes candidates, "t2s.json"
    assert_operator candidates.index("t2s.json"), :<, candidates.index("t2s")
  end

  test "real Simplified conversion covers the Writer regression string" do
    source = "倉頡作書，告黃帝曰：光光𡆠燿。𡆠椻𪫞𝍭〇𝍰𝍨含〜〜\n"
    converted = CharacterStandards.convert(source, :simplified)

    assert_includes converted, "仓颉作书"
    assert_includes converted, "告黄帝曰"
    ["𡆠", "𪫞", "𝍭", "〇", "𝍰", "𝍨", "〜〜"].each { |token| assert_includes converted, token }
    assert converted.end_with?("\n")
  end

end
