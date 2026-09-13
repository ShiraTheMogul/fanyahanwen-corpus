# frozen_string_literal: true

require "test_helper"

module CharacterQuery
  class ReadingSystemTest < ActiveSupport::TestCase
    # The diaeresis in "lu:" is a LETTER distinction, not a tone. Stripping
    # every combining mark merges lu: into lu and nu: into nu, which are not
    # homophones and must not share a slot.
    test "pinyin keeps the diaeresis and drops only tone marks" do
      slot, tone = ReadingSystem.split("lǖ", "mandarin")
      assert_equal "lü", slot
      assert_equal 1, tone

      assert_equal "lu", ReadingSystem.slot_of("lú", "mandarin")
      refute_equal ReadingSystem.slot_of("lǜ", "mandarin"),
                   ReadingSystem.slot_of("lù", "mandarin")
    end

    test "pinyin tones map to the four marks with neutral as five" do
      assert_equal 1, ReadingSystem.split("yī", "mandarin").last
      assert_equal 2, ReadingSystem.split("yí", "mandarin").last
      assert_equal 3, ReadingSystem.split("yǐ", "mandarin").last
      assert_equal 4, ReadingSystem.split("yì", "mandarin").last
      assert_equal 5, ReadingSystem.split("yi", "mandarin").last
    end

    # Horn and circumflex are vowel quality in Vietnamese; only five marks are
    # tones. "u+horn" must not collapse to "u".
    test "vietnamese keeps quality marks and drops tone marks" do
      assert_equal "ư", ReadingSystem.slot_of("ứ", "vietnamese")
      assert_equal "â", ReadingSystem.slot_of("ầ", "vietnamese")
      refute_equal ReadingSystem.slot_of("ư", "vietnamese"),
                   ReadingSystem.slot_of("u", "vietnamese")
    end

    test "jyutping splits a trailing tone digit" do
      assert_equal ["ji", 6], ReadingSystem.split("ji6", "cantonese")
      assert_equal ["zi", nil], ReadingSystem.split("zi", "cantonese")
    end

    test "toneless systems report no tone" do
      assert ReadingSystem.toneless?("japanese_on")
      assert_nil ReadingSystem.split("コウ", "japanese_on").last
    end

    # Regression: an unmarked reading in the DATABASE is the neutral tone, but
    # an unmarked spec typed by a USER means "any tone". Conflating the two made
    # "yi", "yi1" and "yi4" all resolve to tone 5.
    test "slot spec binds a tone only when the spec states one" do
      assert_equal ["yi", nil], ReadingSystem.parse_spec("yi", "mandarin")
      assert_equal ["yi", 1], ReadingSystem.parse_spec("yi1", "mandarin")
      assert_equal ["yi", 4], ReadingSystem.parse_spec("yi4", "mandarin")
      assert_equal ["yi", 1], ReadingSystem.parse_spec("yī", "mandarin")
      assert_equal ["ji", 6], ReadingSystem.parse_spec("ji6", "cantonese")
    end

    test "an unmarked database reading still carries its real tone" do
      assert_equal 5, ReadingSystem.split("yi", "mandarin").last
      assert_equal 6, ReadingSystem.split("ma", "vietnamese").last,
                   "unmarked Vietnamese is ngang, not an absent tone"
    end

    # Regression: Vietnamese tones were Symbols while Query calls #to_i on the
    # tone, so binding a Vietnamese tone raised instead of querying.
    test "every mark-toned and digit-toned system reports an Integer tone" do
      {
        "mandarin" => "yī",
        "vietnamese" => "mọ̣",
        "cantonese" => "ji6"
      }.each do |system, reading|
        assert_kind_of Integer, ReadingSystem.split(reading, system).last,
                       "#{system} tone must be an Integer"
      end
    end

    test "kHanyuPinyin payload yields every packed reading" do
      readings = ReadingSystem.readings_in("10093.130:xíng,xìng", "mandarin_broad")
      assert_equal ["xíng", "xìng"], readings
    end

    test "kHangul payload drops the source suffix" do
      assert_equal ["유"], ReadingSystem.readings_in("유:0E", "korean_hangul")
    end

    test "superscript IPA tones are extracted, not treated as slot" do
      slot, tone = ReadingSystem.split("i³⁵", "topolect:yue:xiaoxuetang_272")
      # Unknown system falls through to plain normalisation; assert the helper
      # directly so the test does not depend on the i18n registry being loaded.
      assert_equal ["i", 35], ReadingSystem.split_superscript("i³⁵")
      assert_not_nil slot
      assert_nil tone
    end
  end
end
