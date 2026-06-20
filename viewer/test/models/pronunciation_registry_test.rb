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

end
