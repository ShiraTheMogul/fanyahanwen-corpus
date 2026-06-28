require "test_helper"

class InterfaceLocalesTest < ActiveSupport::TestCase
  test "only reviewed locales are selectable" do
    assert_equal %i[en lzh], InterfaceLocales::SELECTABLE
    assert InterfaceLocales.selectable?(:en)
    assert InterfaceLocales.selectable?("lzh")
    refute InterfaceLocales.selectable?(:jje)
  end

  test "every locale has a valid visibility status and display name" do
    assert_equal InterfaceLocales::ALL, InterfaceLocales::DEFINITIONS.keys

    InterfaceLocales::DEFINITIONS.each do |code, definition|
      assert_includes InterfaceLocales::VALID_STATUSES, definition.fetch(:status), code
      assert definition.fetch(:native_name).present?, code
    end
  end

  test "selector stays hidden until the project explicitly enables it" do
    refute InterfaceLocales.selector_visible?
  end
end
