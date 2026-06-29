require "test_helper"

class JavascriptTranslationCatalogueTest < ActiveSupport::TestCase
  test "judou toggle uses literal on and off keys in every locale" do
    InterfaceLocales::ALL.each do |locale|
      on_label = I18n.t("javascript.corpus_reader.judou.on", locale: locale, default: nil)
      off_label = I18n.t("javascript.corpus_reader.judou.off", locale: locale, default: nil)

      assert on_label.present?, "missing Judou on label for #{locale}"
      assert off_label.present?, "missing Judou off label for #{locale}"
    end
  end
end
