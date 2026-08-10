# frozen_string_literal: true

require "test_helper"

class CharacterGamesRoundBuilderTest < ActiveSupport::TestCase
  test "component rounds preserve every catalogue membership for duplicate glyphs" do
    rounds = CharacterGames::RoundBuilder.new.component_rounds(limit: Ids::DifficultComponents.unique_glyphs.length)
    duplicate = rounds.find { |round| round[:glyph] == "𠫓" }

    assert duplicate
    assert_includes duplicate[:answers], { stroke_count: "3", stroke_class: "horizontal" }
    assert_includes duplicate[:answers], { stroke_count: "4", stroke_class: "dot" }
  end
end
