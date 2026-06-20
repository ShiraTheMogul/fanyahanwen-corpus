require_relative "../test_helper"

class PronunciationRegistryTest < ActiveSupport::TestCase
  Property = Struct.new(:field, :source, :value)

  setup do
    PronunciationRegistry.reload!
  end

  test "recognises existing registered pronunciation fields" do
    assert PronunciationRegistry.pronunciation_field?("kMandarin")
    assert_equal "mandarin", PronunciationRegistry.family_key_for("kMandarin")
    assert_equal "Mandarin", PronunciationRegistry.label_for_field("kMandarin")
  end

  test "recognises namespaced bulk pronunciation fields" do
    field = "reading.wu.shanghai.ipa"

    assert PronunciationRegistry.pronunciation_field?(field)
    assert_equal "wu", PronunciationRegistry.family_key_for(field)
    assert_equal "IPA", PronunciationRegistry.label_for_field(field)
  end

  test "groups namespaced fields by family and variety" do
    prop = Property.new("reading.wu.shanghai.ipa", "Test source", "zaŋ53")
    section = PronunciationRegistry.pronunciation_sections([prop]).find { |item| item[:key] == "wu" }

    assert_equal "Wu Chinese", section[:label]
    assert_equal 1, section[:count]
    assert_equal "Shanghai", section[:varieties].first[:label]
    assert_equal [prop], section[:varieties].first[:props]
  end

  test "puts hand-maintained prestige and historical readings in second-level groups" do
    japanese_props = [
      Property.new("kJapanese", "Unihan_Readings", "ジ"),
      Property.new("kJapaneseOn", "Unihan_Readings", "JI"),
      Property.new("kJapaneseKun", "Unihan_Readings", "aza")
    ]

    section = PronunciationRegistry.pronunciation_sections(japanese_props)
      .find { |item| item[:key] == "japonic" }
    group = section[:varieties].find { |item| item[:key] == "japanese" }

    assert_empty section[:props]
    assert_equal "Japanese", group[:label]
    assert_equal japanese_props, group[:props]
  end

  test "groups related historical fields under one source dropdown" do
    props = [
      Property.new("guangyun_fanqie", "Guangyun", "武悲"),
      Property.new("guangyun_rhyme", "Guangyun", "支"),
      Property.new("guangyun_tone", "Guangyun", "上平聲")
    ]

    section = PronunciationRegistry.pronunciation_sections(props)
      .find { |item| item[:key] == "middle_chinese" }
    group = section[:varieties].find { |item| item[:key] == "guangyun" }

    assert_empty section[:props]
    assert_equal "Guangyun", group[:label]
    assert_equal props, group[:props]
  end

  test "falls back to a safe dropdown for a registered field without group metadata" do
    prop = Property.new("reading.wu.test_place.ipa", "Test source", "zaŋ53")
    section = PronunciationRegistry.pronunciation_sections([prop])
      .find { |item| item[:key] == "wu" }

    assert_empty section[:props]
    assert_equal "Test Place", section[:varieties].first[:label]
    assert_equal [prop], section[:varieties].first[:props]
  end

  test "ruby source options and lookup use the same registry" do
    assert_includes PronunciationRegistry.ruby_source_keys, :mandarin
    assert_equal "kMandarin", PronunciationRegistry.ruby_source(:mandarin)[:field]
    assert_includes PronunciationRegistry.ruby_source(:mandarin)[:sources], "Unihan_Readings"
  end

  test "ruby sources are grouped by pronunciation family" do
    groups = PronunciationRegistry.ruby_source_groups
    mandarin = groups.find { |group| group[:key] == "mandarin" }

    assert mandarin
    assert_equal "Mandarin Chinese", mandarin[:label]
    assert_includes mandarin[:sources].map { |source| source[:key] }, "mandarin"
    assert_equal "mandarin", PronunciationRegistry.ruby_family_for_source(:mandarin)
  end

  test "prefers English variety labels while keeping Chinese as fallback" do
    assert_equal "Shanghai", PronunciationRegistry.display_variety_label(
      variety_key: "shanghai",
      variety_label: "上海",
      variety_label_en: "Shanghai"
    )

    assert_equal "上海", PronunciationRegistry.display_variety_label(
      variety_key: "shanghai",
      variety_label: "上海",
      variety_label_en: nil
    )
  end

  test "Okinawan entry carries English-first identity location and full references" do
    field = "reading.japonic.okinawan_uchinaaguchi_shuri.ninjal"
    metadata = PronunciationRegistry.field_metadata(field)

    assert_equal "japonic", metadata[:family]
    assert_equal "Okinawan (Uchinaaguchi)", PronunciationRegistry.display_variety_label(metadata)
    assert_equal "Shuri, Naha, Okinawa Island", PronunciationRegistry.display_location_label(metadata)
    assert_equal 2, metadata[:references].length
    assert_match(/10\.15084\/00002266/, metadata[:references].first[:citation])
    assert_match(/okinawa_01\.xlsx/, metadata[:references].last[:citation])
    assert_equal :okinawan_uchinaaguchi_shuri_ninjal,
                 PronunciationRegistry.ruby_source(:okinawan_uchinaaguchi_shuri_ninjal)[:key]
  end

  test "marks the Okinawan ASCII suffix as an accent class annotation" do
    field = "reading.japonic.okinawan_uchinaaguchi_shuri.ninjal"

    assert_equal(
      { base: "?ee", annotation: "1", label: "Accent class" },
      PronunciationRegistry.value_annotation_for(field, "?ee1")
    )
    assert_equal(
      { base: "?ee", annotation: "0*", label: "Accent class" },
      PronunciationRegistry.value_annotation_for(field, "?ee0*")
    )
    assert_nil PronunciationRegistry.value_annotation_for(field, "?ee")
    assert_nil PronunciationRegistry.value_annotation_for("kMandarin", "ai4")
  end

end
