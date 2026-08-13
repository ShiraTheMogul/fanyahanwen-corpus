require_relative "../test_helper"

class HanFontsTest < ActiveSupport::TestCase
  teardown do
    HanFonts.instance_variable_set(:@faces, nil)
    HanFonts.instance_variable_set(:@faces_discovered_at, nil)
  end

  test "development faces reuse a recent discovery" do
    calls = 0
    discovered = [Object.new]
    HanFonts.instance_variable_set(:@faces, nil)
    HanFonts.instance_variable_set(:@faces_discovered_at, nil)

    Rails.env.stub(:development?, true) do
      HanFonts.stub(:discover_faces, -> { calls += 1; discovered }) do
        assert_same discovered, HanFonts.faces
        assert_same discovered, HanFonts.faces
        assert_same discovered, HanFonts.faces
      end
    end

    assert_equal 1, calls
  end
end
