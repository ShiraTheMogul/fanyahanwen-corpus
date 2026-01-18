class XuanjiController < ApplicationController
  include PhoneticizationHelper
  # Display the Xuanji Tu grid + a small reader for extracting paths.
  #
  # Patch 2: allow rule/line_len/speed to be driven by query params so a
  # specific reading can be shared and cited by URL.
  def show
    variant = params[:variant].in?(%w[trad simp]) ? params[:variant] : "trad"

    @grid = XuanjiGrid.includes(:xuanji_cells).find_by!(variant: variant)

    # "Baked in" colour sync:
    # If the Simplified grid exists but is unpainted, copy colours from the
    # Traditional grid automatically so users don't have to click a button.
    auto_sync_colors_if_needed!(@grid)

    # Allowed reading rules (must match Stimulus controller keys)
    allowed_rules = %w[
      rows_lr 
      rows_rl 
      cols_tb 
      cols_bt 
      snake_rows 
      snake_cols 
      kang_first_red 
      kang_second_red 
      kang_third_red 
      kang_third_plus_red 
      kang_fourth_perimeter 
      kang_fifth_blue 
      kang_sixth_purple 
      kang_seventh_yellow 
      kang_perimeter 
      kang_boundary 
      manual
    ]

    @initial_rule = allowed_rules.include?(params[:rule]) ? params[:rule] : "rows_lr"
    @initial_line_len = begin
      n = Integer(params[:line_len] || 7)
      n = 1 if n < 1
      n = 29 if n > 29
      n
    rescue ArgumentError, TypeError
      7
    end

    @initial_speed = begin
      ms = Integer(params[:speed] || 40)
      ms = 10 if ms < 10
      ms = 2000 if ms > 2000
      ms
    rescue ArgumentError, TypeError
      40
    end

    # Build a row-major array of cell payloads for the Stimulus controller.
    indexed = @grid.xuanji_cells.index_by { |c| [c.x, c.y] }
    payload = []
    @grid.height.times do |y|
      @grid.width.times do |x|
        c = indexed.fetch([x, y])
        payload << { x: x, y: y, char: c.char, color: c.color }
      end
    end

    @cells_json = payload.to_json
    @variant = variant
  end

  # Copies colour classes from the traditional grid to the simplified grid.
  # This is important for Kang's colour-dependent reading rules.
  def sync_colors
    # We mirror the show action's variant selection so the button can be a simple POST
    # without needing a grid id.
    variant = params[:variant].in?(%w[trad simp]) ? params[:variant] : "simp"
    grid = XuanjiGrid.find_by!(variant: variant)
    unless grid.variant.to_s == "simp"
      render json: { ok: false, error: "sync_colors only applies to the simplified grid" }, status: :unprocessable_entity
      return
    end

    trad = XuanjiGrid.find_by(name: grid.name, variant: :trad)
    unless trad
      render json: { ok: false, error: "no matching traditional grid found" }, status: :not_found
      return
    end

    Xuanji::SyncColors.call(trad:, simp: grid)
    render json: { ok: true }
  end

  # Phoneticize an array of output lines (used by the Xuanji Tu page).
  #
  # Params (JSON or form):
  #   lines:  ["...", "..."]
  #   system: "mandarin" | "cantonese" | "tang" | "fanqie"
  #
  # Returns:
  #   { ok: true, lines: ["...", ...] }
  def phoneticize
    system = params[:system].to_s

    field =
      case system
      when "cantonese" then "kCantonese"
      when "tang" then "kTang"
      when "fanqie" then "kFanqie"
      else "kMandarin"
      end

    lines = Array(params[:lines]).map(&:to_s)

    # Collect unique Han characters to batch-query.
    uniq = {}
    lines.each do |ln|
      ln.each_char do |ch|
        next unless ch.match?(/\p{Han}/)
        uniq[ch] = true
      end
    end
    chars = uniq.keys

    reading_by_chr = {}
    if chars.any?
      ids_by_chr = CharacterCodepoint.where(chr: chars).pluck(:chr, :id).to_h
      ids = ids_by_chr.values

      if ids.any?
        rows = CharacterProperty.where(character_codepoint_id: ids, field: field)
                                .pluck(:character_codepoint_id, :source, :value)

        pri = { "Unihan_Readings" => 0, "Unihan" => 1 }
        best_by_id = {}
        rows.sort_by { |cid, src, _val| [cid, pri.fetch(src.to_s, 99)] }.each do |cid, _src, val|
          next if best_by_id.key?(cid)
          best_by_id[cid] = val.to_s
        end

        ids_by_chr.each do |chr, cid|
          raw = best_by_id[cid].to_s.strip
          next if raw.blank?
          tok = raw.split(/\s+/).first.to_s
          tok = phoneticize_unihan_value(field, tok)
          reading_by_chr[chr] = tok
        end
      end
    end

    out_lines = lines.map do |ln|
      toks = []
      ln.each_char do |ch|
        next unless ch.match?(/\p{Han}/)
        toks << (reading_by_chr[ch].presence || ch)
      end
      toks.join(" ")
    end

    render json: { ok: true, lines: out_lines }
  rescue StandardError => e
    render json: { ok: false, error: "#{e.class}: #{e.message}" }, status: :unprocessable_entity
  end


  private

  # Heuristic: if this grid is :simp and most cells have no colour assigned,
  # sync colours from the matching :trad grid.
  def auto_sync_colors_if_needed!(grid)
    return unless grid.variant.to_s == "simp"

    cells = grid.xuanji_cells
    return if cells.empty?

    # If >= 90% of cells are nil/blank, treat as "unpainted".
    blank = cells.count { |c| c.color.blank? }
    return if blank.to_f / cells.length < 0.90

    trad = XuanjiGrid.find_by(name: grid.name, variant: :trad)
    return unless trad

    Xuanji::SyncColors.call(trad:, simp: grid)
  rescue StandardError => e
    # Don't break rendering if colour sync fails; show is still usable.
    Rails.logger.warn("[xuanji] auto_sync_colors_if_needed failed: #{e.class}: #{e.message}")
  end
end
