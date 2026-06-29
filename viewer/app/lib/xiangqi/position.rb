# frozen_string_literal: true

module Xiangqi
  class Position
    # Xiangqi FEN uses 10 ranks separated by "/".
    # Common piece letters:
    # r rook, h horse, e elephant, a advisor, k king, c cannon, p pawn
    # Uppercase = Red, lowercase = Black
    START_FEN = "rheakaehr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RHEAKAEHR w - - 0 1"

    attr_reader :board, :side_to_move

    # board[y][x] with y=0 at Red side, x=0 at file a
    def initialize(board:, side_to_move:)
      @board = board
      @side_to_move = side_to_move # "w" (red) or "b" (black)
    end

    def self.start
      from_fen(START_FEN)
    end

    def self.from_fen(fen)
      parts = fen.strip.split
      placement = parts[0]
      stm = parts[1] || "w"

      ranks = placement.split("/")
      raise ArgumentError, I18n.t("fun.xiangqi.errors.fen_ten_ranks") unless ranks.length == 10

      board = Array.new(10) { Array.new(9, nil) }

      # FEN ranks go top->bottom. Our internal y goes bottom->top.
      ranks.each_with_index do |rank_str, fen_rank_idx|
        y = 9 - fen_rank_idx
        x = 0

        rank_str.each_char do |ch|
          if ch >= "1" && ch <= "9"
            x += ch.to_i
          else
            raise ArgumentError, I18n.t("fun.xiangqi.errors.rank_too_long") if x >= 9
            board[y][x] = ch
            x += 1
          end
        end

        raise ArgumentError, I18n.t("fun.xiangqi.errors.rank_nine_files") unless x == 9
      end

      new(board: board, side_to_move: stm)
    end

    def to_fen
      ranks = (9).downto(0).map do |y|
        empties = 0
        out = +""

        0.upto(8) do |x|
          piece = @board[y][x]
          if piece.nil?
            empties += 1
          else
            out << empties.to_s if empties > 0
            empties = 0
            out << piece
          end
        end

        out << empties.to_s if empties > 0
        out
      end

      "#{ranks.join('/')} #{@side_to_move} - - 0 1"
    end

        def piece_at(x, y)
      @board.fetch(y).fetch(x)
    end

    def flip_side!
      @side_to_move = (@side_to_move == "w" ? "b" : "w")
    end

    def clone_for_notation_flip
      # For notation parsing only: we just need a copy with side_to_move flipped.
      self.class.new(
        board: @board, # safe because parsing doesn't mutate the board
        side_to_move: (@side_to_move == "w" ? "b" : "w")
      )
    end
  end
end
