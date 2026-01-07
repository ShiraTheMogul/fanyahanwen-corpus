# frozen_string_literal: true

module Xiangqi
  module Render
    # Grid view: show the raw FEN letter (Latin) so debugging is easy.
    def self.cell_text(piece)
      piece.nil? ? "·" : piece
    end

    # BabelStone Xiangqi uses Unicode symbols in the Miscellaneous Symbols and Pictographs block.
    # We place them on a "box drawing" board so spacing stays stable across fonts.
    PIECE_GLYPHS = {
      # Black (lowercase)
      "r" => "🩫", # chariot
      "h" => "🩪", # horse
      "e" => "🩩", # elephant
      "a" => "🩨", # advisor
      "k" => "🩧", # general
      "c" => "🩬", # cannon
      "p" => "🩭", # pawn

      # Red (uppercase)
      "R" => "🩤", # chariot
      "H" => "🩣", # horse
      "E" => "🩢", # elephant
      "A" => "🩡", # advisor
      "K" => "🩠", # general
      "C" => "🩥", # cannon
      "P" => "🩦"  # pawn
    }.freeze

    # "Pretty" board: a single preformatted string using the BabelStone Xiangqi glyph layout.
    # Coordinates:
    # - x = 0..8 (a..i)
    # - y = 0..9 (red side is y=0)
    # Output is 12 lines: top frame + 10 rank rows + bottom frame.
    def self.pretty_board_text(pos)
      lines = []
      lines << "┏━━━━━━━━━┓"

      9.downto(0) do |y|
        row = base_rank_row(y).chars

        0.upto(8) do |x|
          piece = pos.board[y][x]
          next if piece.nil?
          row[1 + x] = (PIECE_GLYPHS[piece] || piece)
        end

        lines << row.join
      end

      lines << "┗━━━━━━━━━┛"
      lines.join("\n")
    end

    # Base row used for empty intersections.
    # We draw the river as two special ranks:
    # - y=5 uses └┴…┘
    # - y=4 uses ┌┬…┐
    def self.base_rank_row(y)
      inner = if y == 5
                "└" + ("┴" * 7) + "┘"
              elsif y == 4
                "┌" + ("┬" * 7) + "┐"
              else
                "├" + ("┼" * 7) + "┤"
              end

      "┃#{inner}┃"
    end
  end
end
