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

  test "二簡 first round is Mainland Simplified followed by 第一表" do
    CharacterStandards.stub(:simplified, "雪舞道蚯蚓") do
      assert_equal "𫜹午辺丘引", CharacterStandards.convert("雪舞道蚯蚓", :erjian_1)
    end
  end

  test "二簡 second round is cumulative Mainland Simplified then 第一表 then 第二表" do
    calls = []
    CharacterStandards.stub(:simplified, ->(text) { calls << [:simplified, text]; "澳洲鞭子鹦鹉舞数" }) do
      assert_equal "沃洲卞子𰋷武午𮲓", CharacterStandards.convert("澳洲鞭子鹦鹉舞数", :erjian_2)
    end
    assert_equal [[:simplified, "澳洲鞭子鹦鹉舞数"]], calls
  end

  test "二簡 resources have exact reviewed counts, digests, and current Unicode probes" do
    first = CharacterStandards.erjian_round_rules(1)
    second = CharacterStandards.erjian_round_rules(2)

    assert_equal 278, first.length
    assert_equal 266, second.length

    assert_equal CharacterStandardsReliability::ERJIAN_RULE_DIGESTS.fetch(1),
                 CharacterStandards.erjian_rules_digest(first)
    assert_equal CharacterStandardsReliability::ERJIAN_RULE_DIGESTS.fetch(2),
                 CharacterStandards.erjian_rules_digest(second)

    assert_equal "午", first.to_h.fetch("舞")
    assert_equal "𫜹", first.to_h.fetch("雪")
    assert_equal "丘引", first.to_h.fetch("蚯蚓")

    lookup = second.to_h
    assert_equal "沃", lookup.fetch("澳")
    assert_equal "拣", lookup.fetch("捡")
    assert_equal "𥘞", lookup.fetch("襟")
    assert_equal "𥘽", lookup.fetch("襻")
    assert_equal "䃿", lookup.fetch("裤")
    assert_equal "屚", lookup.fetch("漏")
    assert_equal "呙", lookup.fetch("蜗")
    assert_equal "呙", lookup.fetch("娲")
    assert_equal "𬜨", lookup.fetch("繐")
    assert_equal "𬜨", lookup.fetch("𰬸")
    assert_equal "𰋷武", lookup.fetch("鹦鹉")
    assert_equal "𮲓", lookup.fetch("数")
    assert_equal "𫍝", lookup.fetch("谏")
    assert_equal "𱺑", lookup.fetch("缭")
    assert_equal "㝑薄", lookup.fetch("磅礴")
    assert_equal "舢板", lookup.fetch("舢舨")
    assert_equal "刁刻", lookup.fetch("雕刻")
  end

  test "二簡 rejected stand-ins stay out of the executable second table" do
    second = CharacterStandards.erjian_round_rules(2).to_h
    rejected = CharacterStandardsReliability::ERJIAN_REJECTED_STANDIN_KEYS.fetch(2)

    assert_empty rejected.select { |source| second.key?(source) }
  end

  test "二簡 leaves representative unencoded final glyphs unchanged instead of emitting font slots" do
    source = "嚼赢儆瞧艇霞鹰绽涨胀插锸滚磙藤搜嗖飕第嚏斓韩"
    CharacterStandards.stub(:simplified, source) do
      assert_equal source, CharacterStandards.convert(source, :erjian_2)
    end
  end

  test "二簡 restores safe historical mappings and simplified pipeline aliases without broadening word-level rules" do
    source = "捡东西；磅礴；一磅；舢舨；舨；襟襻裤；繐𰬸"
    CharacterStandards.stub(:simplified, source) do
      assert_equal "拣东西；㝑薄；一磅；舢板；舨；𥘞𥘽䃿；𬜨𬜨",
                   CharacterStandards.convert(source, :erjian_2)
    end
  end

  test "二簡 applies the source-explicit carving sense without corrupting bird 雕" do
    source = "老雕雕刻"
    CharacterStandards.stub(:simplified, source) do
      assert_equal "老雕刁刻", CharacterStandards.convert(source, :erjian_2)
    end
  end

  test "二簡 normalises 第二表 word sources through 第一表 before matching" do
    CharacterStandards.stub(:simplified, "叮咛舞") do
      assert_equal "丁宁午", CharacterStandards.convert("叮咛舞", :erjian_2)
    end
  end

  test "二簡 applies each historical table in one pass without same-stage cascades" do
    matcher = CharacterStandards.build_erjian_matcher([
      ["甲", "乙"],
      ["乙", "丙"]
    ])

    assert_equal "乙", CharacterStandards.apply_erjian_matcher("甲", matcher)
  end

  test "二簡 single-pass matching prefers a whole-word rule over its prefix" do
    matcher = CharacterStandards.build_erjian_matcher([
      ["甲", "乙"],
      ["甲乙", "丙"]
    ])

    assert_equal "丙", CharacterStandards.apply_erjian_matcher("甲乙", matcher)
  end

  test "二簡 conversion does not discover stages by scanning VariantMapping sources" do
    VariantMapping.stub(:distinct, ->(*) { flunk "二簡 must not scan VariantMapping.source at conversion time" }) do
      CharacterStandards.stub(:simplified, "舞鞭") do
        assert_equal "午卞", CharacterStandards.convert("舞鞭", :erjian_2)
      end
    end
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
end
