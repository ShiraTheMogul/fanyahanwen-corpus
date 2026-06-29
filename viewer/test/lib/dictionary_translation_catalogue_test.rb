require "test_helper"
require "yaml"

class DictionaryTranslationCatalogueTest < ActiveSupport::TestCase
  def leaf_paths(value, prefix = nil)
    return [prefix] unless value.is_a?(Hash)

    value.flat_map do |key, child|
      path = [prefix, key.to_s].compact.join(".")
      leaf_paths(child, path)
    end
  end

  test "every locale has the complete dictionary catalogue" do
    locale_root = Rails.root.join("config", "locales")
    english = YAML.load_file(locale_root.join("en", "dictionary.yml"), aliases: true).fetch("en").fetch("dictionary")
    expected = leaf_paths(english).sort

    InterfaceLocales::ALL.each do |locale|
      path = locale_root.join(locale.to_s, "dictionary.yml")
      assert path.file?, "missing dictionary catalogue for #{locale}"

      catalogue = YAML.load_file(path, aliases: true).fetch(locale.to_s).fetch("dictionary")
      assert_equal expected, leaf_paths(catalogue).sort, "dictionary keys differ for #{locale}"
    end
  end
end
