class XuanjiController < ApplicationController
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
      rows_lr rows_rl cols_tb cols_bt snake_rows snake_cols
      kang_first_red kang_second_red kang_third_red kang_third_plus_red
      kang_fourth_perimeter kang_fifth_blue kang_sixth_purple kang_seventh_yellow
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
