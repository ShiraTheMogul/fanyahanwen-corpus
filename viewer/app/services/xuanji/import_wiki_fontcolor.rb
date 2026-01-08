# frozen_string_literal: true

module Xuanji
  class ImportWikiFontcolor
    TOKEN_RE = /\{\{\s*fontcolor\s*\|\s*(#[0-9a-fA-F]{6})\s*\|\s*(.*?)\s*\}\}/m

    COLOR_MAP = {
      "#800000" => :maroon,
      "#000000" => :black,
      "#000080" => :navy,
      "#808000" => :olive,
      "#6c3baa" => :purple,
      "#008080" => :teal
    }.freeze

    def initialize(grid:, raw:)
      @grid = grid
      @raw = raw
    end

    def call!
      stream = extract_colored_chars(@raw)
      raise "Expected 841 cells, got #{stream.length}" unless stream.length == 29 * 29

      ApplicationRecord.transaction do
        @grid.update!(width: 29, height: 29)
        @grid.xuanji_cells.delete_all

        stream.each_with_index do |(char, color), i|
          y = i / 29
          x = i % 29
          @grid.xuanji_cells.create!(x: x, y: y, char: char, color: color)
        end
      end

      @grid
    end

    private

    def extract_colored_chars(raw)
      out = []

      raw.scan(TOKEN_RE) do |hex, text|
        color = COLOR_MAP[hex.downcase] || :unknown
        text = normalize(text)

        text.each_char do |ch|
          next if ch == "\n" || ch == "\r"
          out << [ch, color]
        end
      end

      out
    end

    def normalize(s)
      s = s.dup
      s.gsub!(/<br\s*\/?>(?![^<]*<)/i, "\n")
      s.gsub!(/<br\s*\/?>(?=[^<]*<)/i, "\n")
      s.gsub!(/<\/ ?p\b[^>]*>/ix, "")
      s.gsub!(/&nbsp;/i, "")
      s.gsub!(/\s+/, "")
      s
    end
  end
end
