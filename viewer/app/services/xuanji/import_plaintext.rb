# frozen_string_literal: true

module Xuanji
  class ImportPlaintext
    def initialize(grid:, plain:, default_color: :unknown)
      @grid = grid
      @plain = plain
      @default_color = default_color
    end

    def call!
      chars = normalize(@plain)
      raise "Expected 841 characters, got #{chars.length}" unless chars.length == 29 * 29

      ApplicationRecord.transaction do
        @grid.update!(width: 29, height: 29)
        @grid.xuanji_cells.delete_all

        chars.each_with_index do |ch, i|
          y = i / 29
          x = i % 29
          @grid.xuanji_cells.create!(x: x, y: y, char: ch, color: @default_color)
        end
      end

      @grid
    end

    private

    def normalize(s)
      s.lines.map { |ln| ln.strip }.join.each_char.to_a
    end
  end
end
