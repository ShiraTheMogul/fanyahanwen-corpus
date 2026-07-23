# frozen_string_literal: true

require "test_helper"

class DictionaryCatalogueSectionGroupingTest < ActiveSupport::TestCase
  FakeSection = Struct.new(:sequence_number, :tone, keyword_init: true)

  test "keeps canonical tone order" do
    sections = [
      FakeSection.new(sequence_number: 1, tone: "去聲"),
      FakeSection.new(sequence_number: 2, tone: "平聲"),
      FakeSection.new(sequence_number: 3, tone: "入聲"),
      FakeSection.new(sequence_number: 4, tone: "上聲")
    ]

    result = DictionaryCatalogue::SectionGrouping.call(sections)

    assert_equal :tone, result.fetch(:mode)
    assert_equal %w[平聲 上聲 去聲 入聲], result.fetch(:groups).map { |group| group.fetch(:label) }
  end

  test "uses neutral sequence ranges for large non-tone dictionaries" do
    sections = (1..214).map { |number| FakeSection.new(sequence_number: number, tone: nil) }

    result = DictionaryCatalogue::SectionGrouping.call(sections)

    assert_equal :sequence_range, result.fetch(:mode)
    assert_equal ["1–49", "50–99", "100–149", "150–199", "200–214"], result.fetch(:groups).map { |group| group.fetch(:label) }
  end

  test "uses one section group for a small non-tone dictionary" do
    sections = (1..12).map { |number| FakeSection.new(sequence_number: number, tone: nil) }

    result = DictionaryCatalogue::SectionGrouping.call(sections)

    assert_equal :single, result.fetch(:mode)
    assert_equal 1, result.fetch(:groups).length
  end
end
