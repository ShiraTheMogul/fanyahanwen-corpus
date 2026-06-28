require "test_helper"

class PreferencesControllerTest < ActionDispatch::IntegrationTest
  test "accepts a reviewed interface locale" do
    post preferences_url, params: { locale: "lzh", return_to: root_path }
    follow_redirect!

    assert_select "html[lang='lzh']"
  end

  test "rejects a hidden placeholder locale" do
    post preferences_url, params: { locale: "jje", return_to: root_path }
    follow_redirect!

    assert_select "html[lang='en']"
  end
end
