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
    I18n.with_locale(:en) do
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
  end

  test "Literary Chinese reuses stored Chinese topolect labels" do
    metadata = {
      field: "reading.wu.xiaoxuetang_test.ipa",
      group_key: nil,
      group_label: nil,
      group_label_en: nil,
      variety_key: "xiaoxuetang_test",
      variety_label: "上海",
      variety_label_en: "Shanghai",
      location: "上海市",
      location_en: "Shanghai Municipality",
      label: "IPA"
    }

    I18n.with_locale(:en) do
      assert_equal "Shanghai", PronunciationRegistry.display_group_label(metadata)
      assert_equal "Shanghai Municipality", PronunciationRegistry.display_location_label(metadata)
    end

    I18n.with_locale(:lzh) do
      assert_equal "上海", PronunciationRegistry.display_group_label(metadata)
      assert_equal "上海市", PronunciationRegistry.display_location_label(metadata)
    end
  end

  test "ruby source group cache remains locale-specific" do
    english = I18n.with_locale(:en) do
      PronunciationRegistry.ruby_source_groups
        .flat_map { |group| group[:sources] }
        .find { |source| source[:key] == "xiaoxuetang_168" }
        &.fetch(:label)
    end

    literary_chinese = I18n.with_locale(:lzh) do
      PronunciationRegistry.ruby_source_groups
        .flat_map { |group| group[:sources] }
        .find { |source| source[:key] == "xiaoxuetang_168" }
        &.fetch(:label)
    end

    assert_equal "Hukou — IPA", english
    assert_equal "湖口 — IPA", literary_chinese
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


  test "all requested interface locale codes are staged" do
    expected = %i[en ja ryu vie ko jje cmn lzh yue nan wuu cjy hak hsn gan czh cnp csp dng zha ru]

    assert_equal expected, InterfaceLocales::ALL
    expected.each { |locale| assert_includes I18n.available_locales, locale }
    assert_equal %i[en lzh], InterfaceLocales::SELECTABLE
  end

  test "untranslated staged locales use explicit English pronunciation placeholders" do
    metadata = PronunciationRegistry.field_metadata("reading.gan.xiaoxuetang_168.ipa")

    I18n.with_locale(:ru) do
      assert_equal "Hukou", PronunciationRegistry.display_group_label(metadata)
      assert_equal "Hukou — IPA", PronunciationRegistry.display_ruby_source_label(
        PronunciationRegistry.ruby_source(:xiaoxuetang_168)
      )
    end
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

  test "Jejueo fields distinguish standalone and compound-attested readings" do
    direct = PronunciationRegistry.field_metadata("reading.koreanic.jejueo.hangul")
    compound = PronunciationRegistry.field_metadata("reading.koreanic.jejueo.compound_hangul")

    assert_equal "koreanic", direct[:family]
    assert_equal "Jejueo", PronunciationRegistry.display_variety_label(direct)
    assert_equal "Jeju Island", PronunciationRegistry.display_location_label(direct)
    assert_equal "Hangul", direct[:label]
    assert_equal "Hangul (compound-attested)", compound[:label]
    assert_equal 3, direct[:references].length
    assert_equal :jejueo_hangul, PronunciationRegistry.ruby_source(:jejueo_hangul)[:key]
  end

  test "groups Jejueo rows under Koreanic rather than Other" do
    props = [
      Property.new("reading.koreanic.jejueo.hangul", "Yang, Yang & O’Grady 2020", "백"),
      Property.new("reading.koreanic.jejueo.source_romanisation", "Yang, Yang & O’Grady 2020", "beg")
    ]

    sections = PronunciationRegistry.pronunciation_sections(props)
    koreanic = sections.find { |section| section[:key] == "koreanic" }
    other = sections.find { |section| section[:key] == "other" }
    jejueo = koreanic[:varieties].find { |group| group[:key] == "jejueo" }

    assert_equal 2, koreanic[:count]
    assert_equal props, jejueo[:props]
    assert_nil other
  end

end
