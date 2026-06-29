# frozen_string_literal: true

# The Rouxls Kaard!

# This code is very higgledy piggledy and i cant be bothered to fix it

module Xiangqi
  module Notation
    FILES = ("a".."i").to_a
    RED_DIGITS = %w[一 二 三 四 五 六 七 八 九].freeze
    BLACK_DIGITS = %w[1 2 3 4 5 6 7 8 9].freeze

    # System 3 piece aliases / edge cases
    SYSTEM3_PIECE_ALIASES = {
      "CH" => "R",  # Chariot
      "R"  => "R",
      "C"  => "C",
      "H"  => "H",
      "E"  => "E",
      "A"  => "A",
      "G"  => "G",  # General (maps to K/k in piece_letter_from_abbr)
      "K"  => "G",  # some people write K
      "N"  => "H"   # Western "knight"
    }.freeze

    # Public API

    # Parses a whole line that may contain multiple moves separated by whitespace.
    # Uses alternating sides starting from pos.side_to_move (red if "w", black if "b"),
    # which matches common "red black" paste formats.
    #
    # Returns:
    #   { ok: true, moves: [ { raw:, system:, coords: {fx,fy,tx,ty} } ... ] }
    # or
    #   { ok: false, error: "..." }
    def self.parse_line(line, pos)
      s = normalize(line.to_s)
      tokens = s.split(/\s+/).reject(&:empty?)
      return { ok: false, error: I18n.t("fun.xiangqi.errors.enter_move") } if tokens.empty?

      side = (pos.side_to_move.to_s == "b") ? :black : :red
      moves = []

      tokens.each do |tok|
        parsed = parse_token(tok, pos, side)
        return parsed unless parsed[:ok]
        moves << { raw: tok, system: parsed[:system], coords: parsed[:coords] }
        side = (side == :red ? :black : :red)
      end

      { ok: true, moves: moves }
    end

    # Detect token type and dispatch.
    def self.parse_token(tok, pos, side)
      s = normalize(tok.to_s)
      s = strip_trailing_punct(s)

      # ICCS: h2e2 (case-insensitive)
      if s.match?(/\A[a-i][0-9][a-i][0-9]\z/i)
        r = parse_iccs(s)
        return r unless r[:ok]
        return { ok: true, system: :iccs, coords: r[:coords] }
      end

      # System 2 Romanised: C8=7, H8+7, A6+5, also '.' for horizontal.
      # Allows "+/-" as disambiguator instead of from-file digit: C+=5 / C-=5
      if s.match?(/\A[ACEGHRSPaceghrsp][1-9\+\-][=.\+\-][1-9]\z/)
        r = parse_system2_roman(s, pos, side)
        return r unless r[:ok]
        return { ok: true, system: :system2_roman, coords: r[:coords] }
      end

      # System 2 Chinese: 炮八平七 / 砲8平3 / 士6進5 (mixed digits accepted)
      if s.match?(/\A[車馬相象仕士帥將炮砲兵卒][一二三四五六七八九1-9][平進退][一二三四五六七八九1-9]\z/)
        r = parse_system2_chinese(s, pos, side)
        return r unless r[:ok]
        return { ok: true, system: :system2_zh, coords: r[:coords] }
      end

      # System 1: 炮(32)-35 / 砲(38)–33 (hyphen or en dash)
      if s.match?(/\A[車馬相象仕士帥將炮砲兵卒]\(\d{2}\)[\-–]\d{2}\z/)
        r = parse_system1(s, side)
        return r unless r[:ok]
        return { ok: true, system: :system1, coords: r[:coords] }
      end

      # System 3 (Western-ish algebraic), supported:
      #   Hg8
      #   Cbc3
      #   Cxc7
      #   Cxc10#
      # We ignore trailing +/#/?! and treat "x" as capture-required.
      if s.match?(/\A[[:alpha:]].+\z/)
        r = parse_system3(s, pos, side)
        return r unless r[:ok]
        return { ok: true, system: :system3, coords: r[:coords] }
      end

      { ok: false, error: I18n.t("fun.xiangqi.errors.unrecognised_move", token: s) }
    end

    # Convert coords + moved piece letter into System 2 Chinese (e.g. 炮二平五).
    # This is used when the user inputs ICCS / romanised / system3.
    def self.to_chinese(coords, piece_char)
      fx = coords[:fx]; fy = coords[:fy]; tx = coords[:tx]; ty = coords[:ty]
      side = (piece_char == piece_char.upcase) ? :red : :black

      piece = chinese_piece_name(piece_char)
      from_file = file_token_for(side, fx)

      if fy == ty
        to_file = file_token_for(side, tx)
        return "#{piece}#{from_file}平#{to_file}"
      end

      op = forward_op(side, fy, ty)

      if diagonal_piece?(piece_char)
        to_file = file_token_for(side, tx)
        "#{piece}#{from_file}#{op}#{to_file}"
      else
        steps = (ty - fy).abs
        steps_tok = (side == :red) ? RED_DIGITS[steps - 1] : steps.to_s
        "#{piece}#{from_file}#{op}#{steps_tok}"
      end
    end

    def self.iccs_from_coords(fx:, fy:, tx:, ty:)
      "#{FILES[fx]}#{fy}#{FILES[tx]}#{ty}"
    end

    # -------------------------
    # ICCS
    # -------------------------

    def self.parse_iccs(move)
      s = normalize(move.to_s).downcase
      m = s.match(/\A([a-i])([0-9])([a-i])([0-9])\z/)
      return { ok: false, error: I18n.t("fun.xiangqi.errors.iccs_format") } unless m

      fx = FILES.index(m[1])
      fy = m[2].to_i
      tx = FILES.index(m[3])
      ty = m[4].to_i

      { ok: true, coords: { fx: fx, fy: fy, tx: tx, ty: ty } }
    end

    # -------------------------
    # System 2 from Wikipedia (Chinese)
    # -------------------------

    def self.parse_system2_chinese(move, pos, side)
      m = normalize(move).match(/\A([車馬相象仕士帥將炮砲兵卒])([一二三四五六七八九1-9])([平進退])([一二三四五六七八九1-9])\z/)
      return { ok: false, error: I18n.t("fun.xiangqi.errors.chinese_format") } unless m

      zh_piece = m[1]
      from_tok = m[2]
      op       = m[3]
      to_tok   = m[4]

      piece_letter = piece_letter_from_zh(side, zh_piece)
      return { ok: false, error: I18n.t("fun.xiangqi.errors.unknown_piece", piece: zh_piece) } if piece_letter.nil?

      fx = file_x_from_token_relative(side, from_tok)
      fy = resolve_unique_source_y(pos, piece_letter, fx)
      return fy if fy.is_a?(Hash) # error hash

      compute_coords_from_op(side, piece_letter, fx, fy, op, to_tok)
    end

    # -------------------------
    # System 2 from Wikipedia (Romanised)
    # -------------------------

    def self.parse_system2_roman(move, pos, side)
      m = normalize(move).match(/\A([ACEGHRSPaceghrsp])([1-9\+\-])([=.\+\-])([1-9])\z/)
      return { ok: false, error: I18n.t("fun.xiangqi.errors.romanised_format") } unless m

      abbr = m[1].upcase
      from = m[2] # digit or +/-
      op   = m[3]
      to   = m[4]

      piece_letter = piece_letter_from_abbr(side, abbr)
      return { ok: false, error: I18n.t("fun.xiangqi.errors.unknown_piece_abbreviation", abbreviation: abbr) } if piece_letter.nil?

      if from == "+" || from == "-"
        fx = resolve_file_with_multiple(pos, piece_letter)
        return fx if fx.is_a?(Hash) # error hash
        fy = resolve_front_rear_source_y(pos, piece_letter, fx, side, from == "+" ? :front : :rear)
        return fy if fy.is_a?(Hash)
      else
        fx = file_x_from_token_relative(side, from)
        fy = resolve_unique_source_y(pos, piece_letter, fx)
        return fy if fy.is_a?(Hash)
      end

      zh_op = (op == "=" || op == ".") ? "平" : (op == "+" ? "進" : "退")
      compute_coords_from_op(side, piece_letter, fx, fy, zh_op, to)
    end

    # -------------------------
    # System 1 from Wikipedia (炮(32)-35)
    # -------------------------

    # ranks 1..10 from mover's side to far side
    # files 1..9 from mover's RIGHT to LEFT
    def self.parse_system1(move, side)
      s = normalize(move)
      m = s.match(/\A([車馬相象仕士帥將炮砲兵卒])\((\d)(\d)\)[\-–](\d)(\d)\z/)
      return { ok: false, error: I18n.t("fun.xiangqi.errors.system1_format") } unless m

      r1 = m[2].to_i
      f1 = m[3].to_i
      r2 = m[4].to_i
      f2 = m[5].to_i

      return { ok: false, error: I18n.t("fun.xiangqi.errors.system1_ranks") } unless r1.between?(1, 10) && r2.between?(1, 10)
      return { ok: false, error: I18n.t("fun.xiangqi.errors.system1_files") } unless f1.between?(1, 9) && f2.between?(1, 9)

      fx = (side == :red) ? (9 - f1) : (f1 - 1)
      tx = (side == :red) ? (9 - f2) : (f2 - 1)

      fy = (side == :red) ? (r1 - 1) : (10 - r1)
      ty = (side == :red) ? (r2 - 1) : (10 - r2)

      { ok: true, coords: { fx: fx, fy: fy, tx: tx, ty: ty } }
    end

    # -------------------------
    # System 3 from Wikipedia (Western-ish algebraic)
    # -------------------------

    def self.parse_system3(token, pos, side)
      s = normalize(token)

      # strip trailing +/#/?! etc
      s = s.gsub(/[+#?!]+$/, "")

      capture_required = s.include?("x")
      s = s.delete("x")

      piece_abbr, rest = parse_system3_piece_prefix(s)
      piece_abbr ||= "S" # pawn/soldier has no letter in many variants

      piece_letter = piece_letter_from_abbr(side, piece_abbr)
      return { ok: false, error: I18n.t("fun.xiangqi.errors.system3_unknown_piece", piece: piece_abbr) } if piece_letter.nil?

      disambig, dest = parse_system3_disambig_and_dest(rest)
      return { ok: false, error: I18n.t("fun.xiangqi.errors.system3_bad_destination", token: token) } if dest.nil?

      tx = FILES.index(dest[:file])
      ty = dest[:rank] - 1
      return { ok: false, error: I18n.t("fun.xiangqi.errors.system3_bad_destination", token: token) } unless tx && ty.between?(0, 9)

      candidates = []
      0.upto(9) do |fy|
        0.upto(8) do |fx|
          next unless pos.board[fy][fx] == piece_letter
          candidates << { fx: fx, fy: fy }
        end
      end

      if disambig
        if disambig[:type] == :file
          fx_req = FILES.index(disambig[:file])
          candidates.select! { |c| c[:fx] == fx_req }
        else
          y_req = disambig[:rank] - 1
          candidates.select! { |c| c[:fy] == y_req }
        end
      end

      # Prefer Rules if present (stable + correct). Fall back to geometry-only if not loaded.
      if defined?(Xiangqi::Rules) && Xiangqi::Rules.respond_to?(:pseudo_legal_move?)
        candidates.select! do |c|
          ok = Xiangqi::Rules.pseudo_legal_move?(pos, c[:fx], c[:fy], tx, ty)
          if capture_required
            # require that destination is an enemy piece
            dst = pos.board[ty][tx]
            ok && !dst.nil? && (dst == dst.upcase) != (piece_letter == piece_letter.upcase)
          else
            ok
          end
        end
      else
        candidates.select! do |c|
          geometrically_reaches?(piece_letter, c[:fx], c[:fy], tx, ty, side)
        end
      end

      return { ok: false, error: I18n.t("fun.xiangqi.errors.system3_no_source", token: token) } if candidates.empty?
      return { ok: false, error: I18n.t("fun.xiangqi.errors.system3_ambiguous", token: token) } if candidates.length > 1

      src = candidates[0]
      { ok: true, coords: { fx: src[:fx], fy: src[:fy], tx: tx, ty: ty } }
    end

    def self.parse_system3_piece_prefix(s)
      s2 = s.dup

      if s2.length >= 2
        k2 = s2[0, 2].upcase
        if SYSTEM3_PIECE_ALIASES.key?(k2)
          return [SYSTEM3_PIECE_ALIASES[k2], s2[2..]]
        end
      end

      if s2.length >= 1
        k1 = s2[0, 1].upcase
        if SYSTEM3_PIECE_ALIASES.key?(k1)
          return [SYSTEM3_PIECE_ALIASES[k1], s2[1..]]
        end
      end

      [nil, s2]
    end

    # Returns [disambig_hash_or_nil, dest_hash_or_nil]
    # Dest is always like c3 or c10. Optional disambig can be:
    #   file letter (Cbc3) OR rank number (C7c3 style)
    def self.parse_system3_disambig_and_dest(rest)
      r = rest.strip
      m_dest = r.match(/([a-i])(10|[1-9])\z/i)
      return [nil, nil] unless m_dest

      dest = { file: m_dest[1].downcase, rank: m_dest[2].to_i }
      prefix = r[0...m_dest.begin(0)].strip
      return [nil, dest] if prefix.empty?

      if prefix.match?(/\A[a-i]\z/i)
        return [{ type: :file, file: prefix.downcase }, dest]
      end

      if prefix == "10" || prefix.match?(/\A[1-9]\z/)
        return [{ type: :rank, rank: prefix.to_i }, dest]
      end

      [nil, nil]
    end

    # Mapping Han chars to Latin letters

    def self.piece_letter_from_zh(side, zh)
      if side == :red
        case zh
        when "車" then "R"
        when "馬" then "H"
        when "相", "象" then "E"
        when "仕", "士" then "A"
        when "帥", "將" then "K"
        when "炮", "砲" then "C"
        when "兵", "卒" then "P"
        end
      else
        case zh
        when "車" then "r"
        when "馬" then "h"
        when "象", "相" then "e"
        when "士", "仕" then "a"
        when "將", "帥" then "k"
        when "砲", "炮" then "c"
        when "卒", "兵" then "p"
        end
      end
    end

    # A advisor, C cannon, R chariot, E elephant, G general, H horse, S soldier
    def self.piece_letter_from_abbr(side, abbr)
      ab = abbr.to_s.upcase
      red = { "A"=>"A", "C"=>"C", "R"=>"R", "E"=>"E", "G"=>"K", "H"=>"H", "S"=>"P" }
      blk = { "A"=>"a", "C"=>"c", "R"=>"r", "E"=>"e", "G"=>"k", "H"=>"h", "S"=>"p" }
      (side == :red ? red : blk)[ab]
    end

    def self.diagonal_piece?(piece_char)
      u = piece_char.upcase
      u == "H" || u == "E" || u == "A"
    end

    def self.chinese_piece_name(piece_char)
      case piece_char
      when "R" then "車"
      when "H" then "馬"
      when "E" then "相"
      when "A" then "仕"
      when "K" then "帥"
      when "C" then "炮"
      when "P" then "兵"
      when "r" then "車"
      when "h" then "馬"
      when "e" then "象"
      when "a" then "士"
      when "k" then "將"
      when "c" then "砲"
      when "p" then "卒"
      else "？"
      end
    end

    # -------------------------
    # Helpers (coordinates)
    # -------------------------

    # System 2 digits are from mover's RIGHT to LEFT.
    # Accept Chinese digits or Arabic digits.
    def self.file_x_from_token_relative(side, tok)
      if tok.match?(/\A[1-9]\z/)
        n = tok.to_i
      else
        idx = RED_DIGITS.index(tok)
        return nil if idx.nil?
        n = idx + 1
      end

      side == :red ? (9 - n) : (n - 1)
    end

    def self.file_token_for(side, x)
      n = (side == :red) ? (9 - x) : (x + 1)
      (side == :red) ? RED_DIGITS[n - 1] : BLACK_DIGITS[n - 1]
    end

    def self.forward_op(side, fy, ty)
      if side == :red
        ty > fy ? "進" : "退"
      else
        ty < fy ? "進" : "退"
      end
    end

    def self.compute_coords_from_op(side, piece_letter, fx, fy, op, to_tok)
      if op == "平"
        tx = file_x_from_token_relative(side, to_tok)
        return { ok: false, error: I18n.t("fun.xiangqi.errors.bad_file_token", token: to_tok) } if tx.nil?
        return { ok: true, coords: { fx: fx, fy: fy, tx: tx, ty: fy } }
      end

      dir = (side == :red) ? +1 : -1
      dir *= (op == "進" ? 1 : -1)

      if %w[H h E e A a].include?(piece_letter)
        tx = file_x_from_token_relative(side, to_tok)
        return { ok: false, error: I18n.t("fun.xiangqi.errors.bad_file_token", token: to_tok) } if tx.nil?

        dy = (piece_letter.upcase == "H" ? 2 : piece_letter.upcase == "E" ? 2 : 1)
        ty = fy + dir * dy
        return { ok: true, coords: { fx: fx, fy: fy, tx: tx, ty: ty } }
      else
        steps =
          if to_tok.match?(/\A[1-9]\z/)
            to_tok.to_i
          else
            idx = RED_DIGITS.index(to_tok)
            return { ok: false, error: I18n.t("fun.xiangqi.errors.bad_step_token", token: to_tok) } if idx.nil?
            idx + 1
          end

        ty = fy + dir * steps
        return { ok: true, coords: { fx: fx, fy: fy, tx: fx, ty: ty } }
      end
    end

    # -------------------------
    # Helpers (source resolution)
    # -------------------------

    def self.resolve_unique_source_y(pos, piece_letter, fx)
      ys = []
      0.upto(9) { |y| ys << y if pos.board[y][fx] == piece_letter }
      return { ok: false, error: I18n.t("fun.xiangqi.errors.no_piece_on_file", piece: piece_letter) } if ys.empty?
      return { ok: false, error: I18n.t("fun.xiangqi.errors.multiple_pieces_on_file", piece: piece_letter) } if ys.length > 1
      ys[0]
    end

    def self.resolve_front_rear_source_y(pos, piece_letter, fx, side, which)
      ys = []
      0.upto(9) { |y| ys << y if pos.board[y][fx] == piece_letter }
      return { ok: false, error: I18n.t("fun.xiangqi.errors.no_piece_on_file", piece: piece_letter) } if ys.empty?
      return { ok: false, error: I18n.t("fun.xiangqi.errors.need_two_pieces", piece: piece_letter) } if ys.length < 2

      if side == :red
        which == :front ? ys.max : ys.min
      else
        which == :front ? ys.min : ys.max
      end
    end

    def self.resolve_file_with_multiple(pos, piece_letter)
      files = []
      0.upto(8) do |x|
        count = 0
        0.upto(9) { |y| count += 1 if pos.board[y][x] == piece_letter }
        files << x if count > 1
      end
      return { ok: false, error: I18n.t("fun.xiangqi.errors.no_file_with_multiple", piece: piece_letter) } if files.empty?
      return { ok: false, error: I18n.t("fun.xiangqi.errors.multiple_files_ambiguous", piece: piece_letter) } if files.length > 1
      files[0]
    end

    # -------------------------
    # Helpers (System3 fallback geometry)
    # -------------------------

    def self.geometrically_reaches?(piece_letter, fx, fy, tx, ty, side)
      dx = (tx - fx).abs
      dy = (ty - fy).abs
      u = piece_letter.upcase

      case u
      when "R", "C" then fx == tx || fy == ty
      when "H"      then (dx == 1 && dy == 2) || (dx == 2 && dy == 1)
      when "E"      then dx == 2 && dy == 2
      when "A"      then dx == 1 && dy == 1
      when "K"      then (dx == 1 && dy == 0) || (dx == 0 && dy == 1)
      when "P"
        if side == :red
          tx == fx && ty == fy + 1
        else
          tx == fx && ty == fy - 1
        end
      else
        false
      end
    end

    # -------------------------
    # Helpers (normalization)
    # -------------------------

    def self.normalize(s)
      str = s.to_s
      str = str.unicode_normalize(:nfkc) if str.respond_to?(:unicode_normalize)
      str.strip
    end

    def self.strip_trailing_punct(s)
      s.sub(/[，,;；]$/, "")
    end
  end
end
