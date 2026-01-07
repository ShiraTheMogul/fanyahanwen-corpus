# frozen_string_literal: true

class XiangqiController < ApplicationController
  MAX_STORED_MOVES = 300 # soft cap to keep cookie sessions small; may remove later because this would be inconvenient for super long games...

  def show
    @theme = session[:xiangqi_theme].presence || "colour"
    @theme = %w[colour mono grid].include?(@theme) ? @theme : "colour"

    moves_iccs = stored_moves_iccs
    replay_pos, move_infos = replay_from_start(moves_iccs)

    # Use the replayed position as the canonical truth (self-heal if anything drifted).
    session[:xiangqi_fen] = replay_pos.to_fen
    @pos = replay_pos
    @fen = @pos.to_fen
    @board_text = Xiangqi::Render.pretty_board_text(@pos)

    @moves = move_infos
    @last_move = @moves.last

    @side_to_move =
      if defined?(Xiangqi::Rules) && Xiangqi::Rules.respond_to?(:side_to_move)
        Xiangqi::Rules.side_to_move(@pos)
      else
        :red
      end

    @status =
      if defined?(Xiangqi::Rules) && Xiangqi::Rules.respond_to?(:game_status)
        Xiangqi::Rules.game_status(@pos)
      else
        :ok
      end
  end

  def theme
    requested = params[:theme].to_s
    session[:xiangqi_theme] = %w[colour mono grid].include?(requested) ? requested : "colour"

    # JS-driven theme switching should not hard-refresh.
    if request.xhr?
      head :no_content
    else
      redirect_to "/xiangqi", status: :see_other
    end
  end

  # GET /xiangqi/legal_moves?fx=0&fy=0
  def legal_moves
    fen = session[:xiangqi_fen] || Xiangqi::Position::START_FEN
    pos = Xiangqi::Position.from_fen(fen)

    fx = params[:fx].to_i
    fy = params[:fy].to_i

    if fx < 0 || fx > 8 || fy < 0 || fy > 9
      return render json: { ok: false, error: "Bad square." }, status: :unprocessable_entity
    end

    piece = pos.board[fy][fx]
    if piece.nil?
      return render json: { ok: true, fx: fx, fy: fy, piece: nil, moves: [] }
    end

    moves = []
    0.upto(9) do |ty|
      0.upto(8) do |tx|
        next if tx == fx && ty == fy

        if defined?(Xiangqi::Rules) && Xiangqi::Rules.respond_to?(:legal_move?)
          res = Xiangqi::Rules.legal_move?(pos, fx, fy, tx, ty)
          next unless res[:ok]
        else
          next
        end

        target = pos.board[ty][tx]
        capture = !target.nil?
        moves << { tx: tx, ty: ty, capture: capture }
      end
    end

    stm =
      if defined?(Xiangqi::Rules) && Xiangqi::Rules.respond_to?(:side_to_move)
        Xiangqi::Rules.side_to_move(pos)
      else
        :red
      end

    render json: { ok: true, fx: fx, fy: fy, piece: piece, side_to_move: stm.to_s, moves: moves }
  end

  def move
    start_fen = session[:xiangqi_fen] || Xiangqi::Position::START_FEN
    pos = Xiangqi::Position.from_fen(start_fen)

    line = params[:move].to_s
    parsed = Xiangqi::Notation.parse_line(line, pos)

    unless parsed[:ok]
      flash[:alert] = parsed[:error]
      return redirect_to "/xiangqi", status: :see_other
    end

    moves_iccs = stored_moves_iccs
    pending_iccs = []

    parsed[:moves].each do |mv|
      c = mv[:coords]
      fx = c[:fx]; fy = c[:fy]; tx = c[:tx]; ty = c[:ty]

      moved_piece = pos.board[fy][fx]
      if moved_piece.nil?
        flash[:alert] = "No piece at source square."
        return redirect_to "/xiangqi", status: :see_other
      end

      if defined?(Xiangqi::Rules) && Xiangqi::Rules.respond_to?(:legal_move?)
        res = Xiangqi::Rules.legal_move?(pos, fx, fy, tx, ty)
        unless res[:ok]
          flash[:alert] = res[:error] || "Illegal move."
          return redirect_to "/xiangqi", status: :see_other
        end
      end

      # Apply
      pos.board[fy][fx] = nil
      pos.board[ty][tx] = moved_piece
      pos.flip_side!

      iccs = Xiangqi::Notation.iccs_from_coords(**c)
      pending_iccs << iccs
    end

    combined = (moves_iccs + pending_iccs).last(MAX_STORED_MOVES)

    session[:xiangqi_moves] = combined.join(" ")
    session[:xiangqi_fen] = pos.to_fen

    redirect_to "/xiangqi", status: :see_other
  end

  def undo
    moves = stored_moves_iccs
    if moves.empty?
      flash[:alert] = "Nothing to undo."
      return redirect_to "/xiangqi", status: :see_other
    end

    moves.pop
    session[:xiangqi_moves] = moves.join(" ")

    pos, _infos = replay_from_start(moves)
    session[:xiangqi_fen] = pos.to_fen

    redirect_to "/xiangqi", status: :see_other
  end

  # Back-compat: older UI used /xiangqi/view (pretty/grid). Now this is a theme.
  def view_mode
    requested = params[:view].to_s
    session[:xiangqi_theme] = (requested == "grid") ? "grid" : (session[:xiangqi_theme].presence || "colour")
    session[:xiangqi_theme] = "colour" if session[:xiangqi_theme] == "grid" && requested == "pretty"
    redirect_to "/xiangqi", status: :see_other
  end

  def reset
    session.delete(:xiangqi_fen)
    session.delete(:xiangqi_moves)
    redirect_to "/xiangqi", status: :see_other
  end

  private

  def stored_moves_iccs
    raw = session[:xiangqi_moves].to_s
    raw.strip.empty? ? [] : raw.split(/\s+/)
  end

  def replay_from_start(moves_iccs)
    pos = Xiangqi::Position.from_fen(Xiangqi::Position::START_FEN)
    infos = []

    moves_iccs.each do |iccs|
      parsed = Xiangqi::Notation.parse_iccs(iccs)
      break unless parsed.is_a?(Hash) && parsed[:ok]

      coords = parsed[:coords]
      break unless coords.is_a?(Hash)

      fx = coords[:fx]; fy = coords[:fy]; tx = coords[:tx]; ty = coords[:ty]
      break if [fx, fy, tx, ty].any?(&:nil?)

      side_before =
        if defined?(Xiangqi::Rules) && Xiangqi::Rules.respond_to?(:side_to_move)
          Xiangqi::Rules.side_to_move(pos)
        else
          :red
        end

      moved_piece = pos.board[fy][fx]
      break if moved_piece.nil?

      # Apply without re-checking legality (it was checked at entry time).
      pos.board[fy][fx] = nil
      pos.board[ty][tx] = moved_piece
      pos.flip_side!

      suffix =
        if defined?(Xiangqi::Rules) && Xiangqi::Rules.respond_to?(:check_suffix)
          Xiangqi::Rules.check_suffix(pos).to_s
        else
          ""
        end

      zh =
        begin
          Xiangqi::Notation.to_chinese(coords, moved_piece)
        rescue StandardError
          "?"
        end

      infos << {
        "side" => side_before.to_s,
        "iccs_raw" => iccs,
        "iccs" => "#{iccs}#{suffix}",
        "zh" => "#{zh}#{suffix}",
        "fen" => pos.to_fen
      }
    end

    [pos, infos]
  end
end
