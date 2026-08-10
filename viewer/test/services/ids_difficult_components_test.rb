# frozen_string_literal: true

require_relative "../test_helper"

class IdsDifficultComponentsTest < ActiveSupport::TestCase
  test "loads the zi.tools hard-to-input component palette by stroke count and first stroke" do
    groups = Ids::DifficultComponents.groups

    assert_equal %w[1 2 3 4 5 6 7 8 9 10 11 12 13+], groups.map { |group| group.fetch(:stroke_count) }
    assert_equal 542, Ids::DifficultComponents.entries.length
    assert_equal 541, Ids::DifficultComponents.unique_glyphs.length

    first = groups.first.fetch(:classes).index_by { |stroke_class| stroke_class.fetch(:key) }
    assert_equal ["一"], first.fetch("horizontal").fetch(:glyphs)
    assert_equal ["丨"], first.fetch("vertical").fetch(:glyphs)
    assert_equal ["丿"], first.fetch("slash").fetch(:glyphs)
    assert_equal %w[丶 乀], first.fetch("dot").fetch(:glyphs)
    assert_includes first.fetch("turn").fetch(:glyphs), "㇂"
  end

  test "uses the five IRG first-stroke categories with English labels" do
    classes = Ids::DifficultComponents::STROKE_CLASSES

    assert_equal "Horizontal bar", classes.fetch("horizontal").fetch(:english)
    assert_equal "Vertical bar", classes.fetch("vertical").fetch(:english)
    assert_equal "Slash", classes.fetch("slash").fetch(:english)
    assert_equal "Dot", classes.fetch("dot").fetch(:english)
    assert_equal "Turn", classes.fetch("turn").fetch(:english)

    assert_equal %w[橫 豎 撇 點 折], classes.values.map { |row| row.fetch(:han) }
  end

  test "preserves multiple lookup memberships for the same visible component" do
    memberships = Ids::DifficultComponents.memberships_for("𠫓")

    assert_equal 2, memberships.length
    assert memberships.any? { |entry| entry.stroke_count == "3" && entry.stroke_class == "horizontal" }
    assert memberships.any? { |entry| entry.stroke_count == "4" && entry.stroke_class == "dot" }
  end

  test "contains representative structural and non-Han-looking IDS components" do
    {
      "〢" => ["2", "vertical"],
      "〣" => ["3", "vertical"],
      "コ" => ["2", "turn"],
      "𦥑" => ["6", "slash"],
      "𬺻" => ["5", "horizontal"],
      "䜌" => ["13+", "turn"]
    }.each do |glyph, expected|
      entry = Ids::DifficultComponents.memberships_for(glyph).find do |candidate|
        [candidate.stroke_count, candidate.stroke_class] == expected
      end
      assert entry, "expected #{glyph.inspect} at #{expected.inspect}"
    end
  end
end
