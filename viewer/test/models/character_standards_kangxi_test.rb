# frozen_string_literal: true

require_relative "../test_helper"

class CharacterStandardsKangxiTest < ActiveSupport::TestCase
  test "Kangxi modes are available from the shared CharacterStandards registry" do
    assert_includes CharacterStandards.allowed_modes, :kangxi_standard
    assert_includes CharacterStandards.allowed_modes, :kangxi_ancient
    assert CharacterStandards.available?(:kangxi_standard)
    assert CharacterStandards.available?(:kangxi_ancient)
  end

  test "reviewed Kangxi tables have their exact rule counts" do
    assert_equal 6_363, CharacterStandards.kangxi_map(:kangxi_standard).length
    assert_equal 1_294, CharacterStandards.kangxi_map(:kangxi_ancient).length
  end

  test "Kangxi Standard applies reviewed WFG preferences after Standard Traditional" do
    CharacterStandards.stub(:traditional, "為青真群衛床峰塚埋桒塡朵匩靵") do
      assert_equal "爲靑眞羣衞牀峯冢埋桑填朵匩靵",
                   CharacterStandards.convert("ignored", :kangxi_standard)
    end
  end

  test "Kangxi 古文 is deterministic and layered over Kangxi Standard" do
    CharacterStandards.stub(:kangxi_standard_from_any, "爲靑眞朵") do
      assert_equal "𦥮𡴑𡙊㙐", CharacterStandards.convert("ignored", :kangxi_ancient)
    end
  end

  test "ambiguous Kangxi relationships are omitted from plain-text conversion" do
    map = CharacterStandards.kangxi_map(:kangxi_standard)
    refute map.key?("靵")
    refute map.key?("匩")
  end
end
