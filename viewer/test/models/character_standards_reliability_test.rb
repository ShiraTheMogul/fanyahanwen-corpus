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

  test "二簡 first round is Mainland Simplified followed by first-round overlay" do
    CharacterStandards.stub(:simplified, "传体") do
      CharacterStandards.stub(:erjian_round_map, ->(round) { round == 1 ? { "传" => "伝" } : {} }) do
        assert_equal "伝体", CharacterStandards.convert("傳體", :erjian_1)
      end
    end
  end

  test "二簡 second round is cumulative Mainland Simplified then first round then second round" do
    calls = []
    CharacterStandards.stub(:simplified, ->(text) { calls << [:simplified, text]; "传体" }) do
      CharacterStandards.stub(:erjian_round_map, ->(round) {
        calls << [:round, round]
        round == 1 ? { "传" => "伝" } : { "伝" => "仮" }
      }) do
        assert_equal "仮体", CharacterStandards.convert("傳體", :erjian_2)
      end
    end
    assert_equal [[:simplified, "傳體"], [:round, 1], [:round, 2]], calls
  end

  test "Singapore 1969 keeps its own Traditional base and never enters the 二簡 chain" do
    CharacterStandards.stub(:traditional, "傳體") do
      CharacterStandards.stub(:simplified, ->(*) { flunk "Singapore 1969 must not use Mainland Simplified" }) do
        CharacterStandards.stub(:singapore_1969_map, { "傳" => "传" }) do
          assert_equal "传體", CharacterStandards.convert("傳體", :singapore_1969)
        end
      end
    end
  end

  test "二簡 source labels are separated into first and second rounds" do
    assert_equal 1, CharacterStandards.erjian_source_round("二簡字 第一表")
    assert_equal 1, CharacterStandards.erjian_source_round("Second Chinese Character Simplification Scheme — First List")
    assert_equal 2, CharacterStandards.erjian_source_round("二简字 第二表")
    assert_equal 2, CharacterStandards.erjian_source_round("Second Chinese Character Simplification Scheme — Second List")
    assert_nil CharacterStandards.erjian_source_round("Singapore 1969 简体字表")
  end

end
