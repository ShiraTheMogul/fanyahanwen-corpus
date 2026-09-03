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

  test "related font variants are grouped but singletons stay in the catch-all group" do
    face = HanFonts::FontFace
    sample = [
      face.new(key: :wenjin_mincho, label: "WenJin Mincho", family: "WenJin Mincho", group: nil),
      face.new(key: :lxgw_light, label: "LXGW Light", family: "LXGW Light", group: "LXGW WenKai KR"),
      face.new(key: :lxgw_regular, label: "LXGW Regular", family: "LXGW Regular", group: "LXGW WenKai KR"),
      face.new(key: :pengli, label: "Pengli WenKai", family: "Pengli", group: "Pengli")
    ]

    HanFonts.stub(:faces, sample) do
      groups = HanFonts.choice_groups(ungrouped_label: "Other fonts")
      assert_equal ["Other fonts", "LXGW WenKai KR"], groups.map(&:first)
      assert_equal ["Pengli WenKai", "WenJin Mincho"], groups.first.last.map(&:first)
      assert_equal ["LXGW Light", "LXGW Regular"], groups.last.last.map(&:first)
    end
  end
end
