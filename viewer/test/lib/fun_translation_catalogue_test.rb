require "test_helper"
require "yaml"

class FunTranslationCatalogueTest < ActiveSupport::TestCase
  def leaf_paths(value, prefix = nil)
    return [prefix] unless value.is_a?(Hash)

    value.flat_map do |key, child|
      path = [prefix, key.to_s].compact.join(".")
      leaf_paths(child, path)
    end
  end

  test "every locale has the complete Fun catalogue" do
    locale_root = Rails.root.join("config", "locales")
    english = YAML.load_file(locale_root.join("en", "fun.yml"), aliases: true).fetch("en")
    expected_fun = leaf_paths(english.fetch("fun")).sort
    expected_javascript = leaf_paths(english.fetch("javascript").fetch("fun")).sort

    InterfaceLocales::ALL.each do |locale|
      path = locale_root.join(locale.to_s, "fun.yml")
      assert path.file?, "missing Fun catalogue for #{locale}"

      catalogue = YAML.load_file(path, aliases: true).fetch(locale.to_s)
      assert_equal expected_fun, leaf_paths(catalogue.fetch("fun")).sort,
                   "Fun keys differ for #{locale}"
      assert_equal expected_javascript, leaf_paths(catalogue.fetch("javascript").fetch("fun")).sort,
                   "Fun JavaScript keys differ for #{locale}"
    end
  end
end
