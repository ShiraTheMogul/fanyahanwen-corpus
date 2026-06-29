# frozen_string_literal: true

module Xiangqi
  module Rules
    # Coordinate system:
    # board[y][x], x=0..8 (a..i), y=0..9 (red side at y=0)
    #
    # Side symbols:
    # :red   -> uppercase pieces
    # :black -> lowercase pieces

    def self.in_bounds?(x, y) = x.between?(0, 8) && y.between?(0, 9)

    def self.red_piece?(ch) = !ch.nil? && ch == ch.upcase
    def self.black_piece?(ch) = !ch.nil? && ch == ch.downcase

    def self.side_of_piece(ch)
      return nil if ch.nil?
      red_piece?(ch) ? :red : :black
    end

    def self.other_side(side) = (side == :red ? :black : :red)

    def self.same_side?(a, b)
      return false if a.nil? || b.nil?
      side_of_piece(a) == side_of_piece(b)
    end

    def self.enemy?(a, b)
      return false if a.nil? || b.nil?
      side_of_piece(a) != side_of_piece(b)
    end

    def self.side_to_move(pos)
      pos.side_to_move.to_s == "b" ? :black : :red
    end

    # ---------- Palace / river helpers ----------

    def self.in_palace?(side, x, y)
      return false unless x.between?(3, 5)
      side == :red ? y.between?(0, 2) : y.between?(7, 9)
    end

    def self.crossed_river?(side, y)
      # River is between y=4 and y=5 in this coordinate convention.
      side == :red ? y >= 5 : y <= 4
    end

    # ---------- Line scanning ----------

    def self.count_between_line(board, fx, fy, tx, ty)
      return nil unless fx == tx || fy == ty
      count = 0

      if fx == tx
        step = ty > fy ? 1 : -1
        y = fy + step
        while y != ty
          count += 1 unless board[y][fx].nil?
          y += step
        end
      else
        step = tx > fx ? 1 : -1
        x = fx + step
        while x != tx
          count += 1 unless board[fy][x].nil?
          x += step
        end
      end

      count
    end

    # ---------- Locate generals ----------

    def self.find_general(pos, side)
      target = (side == :red) ? "K" : "k"
      0.upto(9) do |y|
        0.upto(8) do |x|
          return [x, y] if pos.board[y][x] == target
        end
      end
      nil
    end

    def self.generals_face?(pos)
      rk = find_general(pos, :red)
      bk = find_general(pos, :black)
      return false if rk.nil? || bk.nil?

      rx, ry = rk
      bx, by = bk
      return false unless rx == bx

      between = count_between_line(pos.board, rx, ry, bx, by)
      between == 0
    end

    # ---------- Attack rules (this is the heart of "check") ----------

    # True if the piece at (fx,fy) attacks (tx,ty) in the current position.
    # This uses CAPTURE-style rules (cannon needs exactly one screen if target occupied, etc.).
    def self.attacks_square?(pos, fx, fy, tx, ty)
      board = pos.board
      return false unless in_bounds?(fx, fy) && in_bounds?(tx, ty)
      piece = board[fy][fx]
      return false if piece.nil?

      side = side_of_piece(piece)
      target = board[ty][tx]
      return false if !target.nil? && same_side?(piece, target)

      u = piece.upcase
      dx = tx - fx
      dy = ty - fy
      adx = dx.abs
      ady = dy.abs

      case u
      when "R" # chariot
        return false unless fx == tx || fy == ty
        count_between_line(board, fx, fy, tx, ty) == 0

      when "C" # cannon
        return false unless fx == tx || fy == ty
        between = count_between_line(board, fx, fy, tx, ty)
        return false if between.nil?
        if target.nil?
          between == 0
        else
          between == 1
        end

      when "H" # horse (blocked by "leg")
        return false unless (adx == 2 && ady == 1) || (adx == 1 && ady == 2)
        leg_x = fx + (adx == 2 ? (dx < 0 ? -1 : 1) : 0)
        leg_y = fy + (ady == 2 ? (dy < 0 ? -1 : 1) : 0)
        board[leg_y][leg_x].nil?

      when "E" # elephant (blocked by "eye", cannot cross river)
        return false unless adx == 2 && ady == 2
        eye_x = fx + (dx < 0 ? -1 : 1)
        eye_y = fy + (dy < 0 ? -1 : 1)
        return false unless board[eye_y][eye_x].nil?
        side == :red ? (ty <= 4) : (ty >= 5)

      when "A" # advisor (palace diagonal 1)
        return false unless adx == 1 && ady == 1
        in_palace?(side, tx, ty)

      when "K" # general (palace orthogonal 1)
        return false unless (adx == 1 && ady == 0) || (adx == 0 && ady == 1)
        in_palace?(side, tx, ty)

      when "P" # pawn / soldier attacks the same way it moves
        fwd = (side == :red) ? +1 : -1
        if tx == fx && ty == fy + fwd
          true
        elsif crossed_river?(side, fy) && adx == 1 && ady == 0
          true
        else
          false
        end

      else
        false
      end
    end

    # ---------- Check detection ----------

    def self.in_check?(pos, side)
      g = find_general(pos, side)
      return false if g.nil?
      gx, gy = g

      enemy_side = other_side(side)

      0.upto(9) do |fy|
        0.upto(8) do |fx|
          piece = pos.board[fy][fx]
          next if piece.nil?
          next unless side_of_piece(piece) == enemy_side
          return true if attacks_square?(pos, fx, fy, gx, gy)
        end
      end

      false
    end

    # ---------- Pseudo-legal movement with explicit errors ----------

    # Returns { ok: true } or { ok: false, error: "..." }.
    def self.pseudo_legal_move_result(pos, fx, fy, tx, ty)
      board = pos.board
      return { ok: false, error: I18n.t("fun.xiangqi.errors.move_out_of_bounds") } unless in_bounds?(fx, fy) && in_bounds?(tx, ty)
      return { ok: false, error: I18n.t("fun.xiangqi.errors.same_square") } if fx == tx && fy == ty

      piece = board[fy][fx]
      return { ok: false, error: I18n.t("fun.xiangqi.errors.no_piece_source") } if piece.nil?

      target = board[ty][tx]
      return { ok: false, error: I18n.t("fun.xiangqi.errors.capture_own_piece") } if same_side?(piece, target)

      side = side_of_piece(piece)
      u = piece.upcase

      dx = tx - fx
      dy = ty - fy
      adx = dx.abs
      ady = dy.abs

      case u
      when "R"
        return { ok: false, error: I18n.t("fun.xiangqi.errors.chariot_straight") } unless fx == tx || fy == ty
        return { ok: false, error: I18n.t("fun.xiangqi.errors.chariot_blocked") } unless count_between_line(board, fx, fy, tx, ty) == 0
        return { ok: true }

      when "C"
        return { ok: false, error: I18n.t("fun.xiangqi.errors.cannon_straight") } unless fx == tx || fy == ty
        between = count_between_line(board, fx, fy, tx, ty)
        return { ok: false, error: I18n.t("fun.xiangqi.errors.cannon_line_invalid") } if between.nil?

        if target.nil?
          return { ok: false, error: I18n.t("fun.xiangqi.errors.cannon_no_jump") } unless between == 0
        else
          return { ok: false, error: I18n.t("fun.xiangqi.errors.cannon_one_screen") } unless between == 1
        end
        return { ok: true }

      when "H"
        return { ok: false, error: I18n.t("fun.xiangqi.errors.horse_shape") } unless (adx == 2 && ady == 1) || (adx == 1 && ady == 2)
        leg_x = fx + (adx == 2 ? (dx < 0 ? -1 : 1) : 0)
        leg_y = fy + (ady == 2 ? (dy < 0 ? -1 : 1) : 0)
        return { ok: false, error: I18n.t("fun.xiangqi.errors.horse_blocked") } unless board[leg_y][leg_x].nil?
        return { ok: true }

      when "E"
        return { ok: false, error: I18n.t("fun.xiangqi.errors.elephant_diagonal") } unless adx == 2 && ady == 2
        eye_x = fx + (dx < 0 ? -1 : 1)
        eye_y = fy + (dy < 0 ? -1 : 1)
        return { ok: false, error: I18n.t("fun.xiangqi.errors.elephant_blocked") } unless board[eye_y][eye_x].nil?
        river_ok = (side == :red) ? (ty <= 4) : (ty >= 5)
        return { ok: false, error: I18n.t("fun.xiangqi.errors.elephant_river") } unless river_ok
        return { ok: true }

      when "A"
        return { ok: false, error: I18n.t("fun.xiangqi.errors.advisor_diagonal") } unless adx == 1 && ady == 1
        return { ok: false, error: I18n.t("fun.xiangqi.errors.advisor_palace") } unless in_palace?(side, tx, ty)
        return { ok: true }

      when "K"
        return { ok: false, error: I18n.t("fun.xiangqi.errors.general_orthogonal") } unless (adx == 1 && ady == 0) || (adx == 0 && ady == 1)
        return { ok: false, error: I18n.t("fun.xiangqi.errors.general_palace") } unless in_palace?(side, tx, ty)
        return { ok: true }

      when "P"
        fwd = (side == :red) ? +1 : -1
        if tx == fx && ty == fy + fwd
          return { ok: true }
        end

        if crossed_river?(side, fy) && adx == 1 && ady == 0
          return { ok: true }
        end

        if adx == 1 && ady == 0
          return { ok: false, error: I18n.t("fun.xiangqi.errors.soldier_sideways") }
        end

        return { ok: false, error: I18n.t("fun.xiangqi.errors.soldier_move") }

      else
        { ok: false, error: I18n.t("fun.xiangqi.errors.unknown_piece_type") }
      end
    end

    def self.pseudo_legal_move?(pos, fx, fy, tx, ty)
      pseudo_legal_move_result(pos, fx, fy, tx, ty)[:ok]
    end

    # ---------- Full legality (includes king safety) ----------

    def self.legal_move?(pos, fx, fy, tx, ty)
      piece = pos.board[fy][fx]
      return { ok: false, error: I18n.t("fun.xiangqi.errors.no_piece_source") } if piece.nil?

      mover = side_of_piece(piece)
      return { ok: false, error: I18n.t("fun.xiangqi.errors.not_your_turn") } unless mover == side_to_move(pos)

      pre = pseudo_legal_move_result(pos, fx, fy, tx, ty)
      return pre unless pre[:ok]

      # simulate move
      captured = pos.board[ty][tx]
      pos.board[fy][fx] = nil
      pos.board[ty][tx] = piece

      # Special xiangqi rule: the two generals may not "face" each other with no pieces between.
      if generals_face?(pos)
        # revert
        pos.board[fy][fx] = piece
        pos.board[ty][tx] = captured
        return { ok: false, error: I18n.t("fun.xiangqi.errors.generals_face") }
      end

      illegal = in_check?(pos, mover)

      # revert
      pos.board[fy][fx] = piece
      pos.board[ty][tx] = captured

      return { ok: false, error: I18n.t("fun.xiangqi.errors.leaves_general_in_check") } if illegal

      { ok: true }
    end

    # ---------- End states / suffixes ----------

    def self.any_legal_moves?(pos, side)
      stm = side_to_move(pos)
      return false unless stm == side

      0.upto(9) do |fy|
        0.upto(8) do |fx|
          piece = pos.board[fy][fx]
          next if piece.nil?
          next unless side_of_piece(piece) == side

          0.upto(9) do |ty|
            0.upto(8) do |tx|
              next if fx == tx && fy == ty
              next unless pseudo_legal_move?(pos, fx, fy, tx, ty)
              res = legal_move?(pos, fx, fy, tx, ty)
              return true if res[:ok]
            end
          end
        end
      end

      false
    end

    # Returns :ok, :check, :checkmate, :stalemate
    def self.game_status(pos)
      side = side_to_move(pos)
      chk = in_check?(pos, side)
      has = any_legal_moves?(pos, side)

      if has
        chk ? :check : :ok
      else
        # In xiangqi, stalemate is a loss for the stalemated player.
        chk ? :checkmate : :stalemate
      end
    end

    def self.check_suffix(pos)
      st = game_status(pos)
      return "#" if st == :checkmate || st == :stalemate
      return "+" if st == :check
      ""
    end
  end
end
