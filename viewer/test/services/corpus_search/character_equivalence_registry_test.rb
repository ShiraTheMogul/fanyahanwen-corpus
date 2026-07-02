require_relative "../../test_helper"

class CorpusSearchCharacterEquivalenceRegistryTest < ActiveSupport::TestCase
  setup do
    CorpusSearch::CharacterEquivalenceRegistry.reset_cache!
  end

  teardown do
    CorpusSearch::CharacterEquivalenceRegistry.reset_cache!
  end

  test "exact matching never expands a character" do
    registry = CorpusSearch::CharacterEquivalenceRegistry.new(level: "exact")

    assert_equal ["驗"], registry.forms_for("驗").to_a
    assert_not registry.equivalent?("驗", "験")
  end

  test "common matching consumes the shared VariantMapping registry" do
    VariantMapping.delete_all
    VariantMapping.create!(
      base_codepoint: "為".ord,
      variant_codepoint: "爲".ord,
      source: "moe_taiwan_moe"
    )
    CorpusSearch::CharacterEquivalenceRegistry.reset_cache!

    registry = CorpusSearch::CharacterEquivalenceRegistry.new(level: "common")
    explanation = registry.explanation(query_character: "為", source_character: "爲")

    assert registry.equivalent?("為", "爲")
    assert_equal ["taiwan_moe"], explanation.fetch("mapping_sources")
    assert_equal ["為", "爲"], explanation.fetch("mapping_path")
  end

  test "broad matching links traditional simplified and Japanese forms through OpenCC" do
    registry = CorpusSearch::CharacterEquivalenceRegistry.new(level: "broad")
    explanation = registry.explanation(query_character: "驗", source_character: "験")

    assert registry.equivalent?("驗", "験")
    assert registry.equivalent?("驗", "验")
    assert_includes explanation.fetch("mapping_sources"), "opencc_japanese_shinjitai"
    assert_equal "驗", explanation.fetch("mapping_path").first
    assert_equal "験", explanation.fetch("mapping_path").last
  end
end
