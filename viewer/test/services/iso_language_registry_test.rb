require_relative "../test_helper"

class IsoLanguageRegistryTest < ActiveSupport::TestCase
  test "accepts ISO 639-3 language codes" do
    assert IsoLanguageRegistry.include?("eng")
    assert IsoLanguageRegistry.include?("yue")
    assert_equal "English", IsoLanguageRegistry.name_for("eng")
  end

  test "rejects unknown and non-three-letter codes" do
    refute IsoLanguageRegistry.include?("en")
    refute IsoLanguageRegistry.include?("zzz")
    assert_nil IsoLanguageRegistry.name_for("zzz")
  end
end
