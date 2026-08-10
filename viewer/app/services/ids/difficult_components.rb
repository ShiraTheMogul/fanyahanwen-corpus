# frozen_string_literal: true

require "yaml"

module Ids
  # Curated palette for IDS components that are awkward to type directly.
  #
  # zi.tools arranges these by total stroke count and then by the component's
  # first stroke. The arrangement is useful independently of zi.tools: a user
  # transcribing an unknown glyph can often estimate these two facts even when
  # they do not know the component's name or Unicode codepoint.
  #
  # Keep this separate from Ids::Parser. The parser answers "is this valid IDS
  # structure?"; this catalogue answers "how can a human find a component?".
  class DifficultComponents
    DATA_PATH = Rails.root.join("config/data/ids_difficult_components.yml")

    STROKE_CLASSES = {
      "horizontal" => { han: "橫", english: "Horizontal bar", representative: "一" },
      "vertical" => { han: "豎", english: "Vertical bar", representative: "丨" },
      "slash" => { han: "撇", english: "Slash", representative: "丿" },
      "dot" => { han: "點", english: "Dot", representative: "丶" },
      "turn" => { han: "折", english: "Turn", representative: "乙" }
    }.freeze

    Entry = Struct.new(
      :glyph,
      :codepoint,
      :stroke_count,
      :stroke_class,
      :stroke_class_han,
      :stroke_class_english,
      keyword_init: true
    )

    class << self
      def groups
        @groups ||= begin
          raw_data.map do |stroke_count, classes|
            {
              stroke_count: stroke_count,
              classes: STROKE_CLASSES.map do |key, labels|
                glyphs = graphemes(classes.fetch(key, ""))
                {
                  key: key,
                  han: labels.fetch(:han),
                  english: labels.fetch(:english),
                  representative: labels.fetch(:representative),
                  glyphs: glyphs
                }
              end
            }
          end.freeze
        end
      end

      def entries
        @entries ||= groups.flat_map do |group|
          group.fetch(:classes).flat_map do |stroke_class|
            stroke_class.fetch(:glyphs).map do |glyph|
              Entry.new(
                glyph: glyph,
                codepoint: glyph.codepoints.one? ? glyph.ord : nil,
                stroke_count: group.fetch(:stroke_count),
                stroke_class: stroke_class.fetch(:key),
                stroke_class_han: stroke_class.fetch(:han),
                stroke_class_english: stroke_class.fetch(:english)
              )
            end
          end
        end.freeze
      end

      def unique_glyphs
        @unique_glyphs ||= entries.map(&:glyph).uniq.freeze
      end

      def memberships_for(glyph)
        entries.select { |entry| entry.glyph == glyph.to_s }
      end

      private

      def raw_data
        @raw_data ||= YAML.safe_load_file(DATA_PATH, aliases: false).freeze
      end

      def graphemes(text)
        text.to_s.scan(/\X/)
      end
    end
  end
end
