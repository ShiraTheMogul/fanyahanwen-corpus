class XuanjiController < ApplicationController
  include PhoneticizationHelper
  # Display the Xuanji Tu grid + a small reader for extracting paths.
  #
  # Patch 2: allow rule/line_len/speed to be driven by query params so a
  # specific reading can be shared and cited by URL.
  def show
    variant = params[:variant].in?(%w[trad simp]) ? params[:variant] : "trad"

    # ONE STORED GRID. THE SIMPLIFIED ONE IS DERIVED.
    # ----------------------------------------------
    # There used to be two XuanjiGrid records, trad and simp, and a pile of
    # machinery to keep them in step: auto_sync_colors_if_needed! copied the
    # colours across on render, and the sync_colors endpoint did it on demand.
    # All of that existed because a second stored grid can disagree with the
    # first — and the colours are the PARSE here, so a disagreement is a wrong
    # reading, not a wrong palette.
    #
    # The figure is the traditional one. Simplification is a display choice, so
    # it is now applied at display time: load trad, convert each cell through
    # CharacterStandards.convert(ch, :simplified), which is OpenCC t2s. The
    # offline application derives its simplified grid the same way from the same
    # config, so the two front ends cannot drift apart either.
    #
    # ONE CELL AT A TIME, which matters: t2s normally resolves ambiguity from
    # surrounding text and there is no surrounding text in a grid. A cell belongs
    # to seven poems reading in seven directions, so phrase-aware conversion
    # would be reading context that is not there.
    @grid = XuanjiGrid.includes(:xuanji_cells).find_by!(variant: "trad")
    @variant = variant
    @simplification_unavailable = false

    # Allowed reading rules (must match Stimulus controller keys)
    #
    # The eight kang_* rules are 康萬民's eight figures of the 璇璣圖, and until
    # now they were listed here and implemented nowhere: `buildPath` in
    # xuanji_controller.js had no case for any of them, so every one fell
    # through to its `default` and read the grid left to right in rows. The
    # dropdown said 第三圖 and the reader gave you rows of seven, with no error.
    #
    # `kang_fourth_black` is the same figure as `kang_fourth_perimeter`, under a
    # name that is not wrong: 第四圖 is 四隅, the four CORNERS, and not a
    # perimeter of anything. The old name is kept so existing links still work.
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
      kang_third_one
      kang_third_one_w1
      kang_third_one_w2
      kang_third_one_w3
      kang_third_one_w4
      kang_third_two
      kang_third_two_w1
      kang_third_two_w2
      kang_third_two_w3
      kang_third_two_w4
      kang_third_three
      kang_third_three_w1
      kang_third_three_w2
      kang_third_three_w3
      kang_third_three_w4
      kang_third_four
      kang_third_four_w1
      kang_third_four_w2
      kang_third_four_w3
      kang_third_four_w4
      kang_third_five
      kang_third_five_w1
      kang_third_five_w2
      kang_third_five_w3
      kang_third_five_w4
      kang_dieci_one
      kang_dieci_one_p1
      kang_dieci_two
      kang_dieci_two_p1
      kang_dieci_five
      kang_dieci_five_p1
      kang_fuzeng_rays
      kang_fuzeng_first
      kang_fuzeng_second
      kang_fuzeng_third
      kang_fourth_black
      kang_fourth_split
      kang_fourth_black_alt
      kang_fourth_split_alt
      kang_fourth_odd
      kang_fourth_odd_rev
      kang_fourth_borrow1
      kang_fourth_borrow1_alt
      kang_fourth_borrow2
      kang_fourth_borrow2_alt
      kang_fourth_perimeter
      kang_fifth_blue
      kang_fifth_borrowed
      kang_fifth_six
      kang_fifth_both
      kang_fifth_four
      kang_fifth_both_alt
      kang_fifth_four12
      kang_fifth_four12_alt
      kang_fifth_four6_alt
      kang_fifth_six_alt
      kang_sixth_purple
      kang_seventh_yellow
      kang_sixth_outin
      kang_sixth_inout
      kang_seventh_outin
      kang_seventh_inout
      kang_seventh_inter
      kang_perimeter
      kang_boundary
      manual
      kang_first_ring
      kang_second_ring
      kang_first_ring_w1
      kang_first_ring_w2
      kang_first_ring_w3
      kang_first_ring_w4
      kang_first_ring_w5
      kang_first_ring_w6
      kang_first_ring_w7
      kang_first_ring_w8
      kang_first_ring_w9
      kang_first_ring_w10
      kang_first_ring_w11
      kang_first_ring_w12
      kang_first_ring_w13
      kang_first_ring_w14
      kang_first_ring_w15
      kang_first_ring_w16
      kang_first_circuit
      kang_first_circuit_s1
      kang_first_circuit_s7
      kang_second_ring_w1
      kang_second_ring_w2
      kang_second_ring_w3
      kang_second_ring_w4
      kang_second_ring_w5
      kang_second_ring_w6
      kang_second_ring_w7
      kang_second_ring_w8
      kang_first_circuit_tr
      kang_first_circuit_br
      kang_first_circuit_bl
      kang_first_circuit_tr_s1
      kang_first_circuit_tr_s7
      kang_first_circuit_br_s1
      kang_first_circuit_br_s7
      kang_first_circuit_bl_s1
      kang_first_circuit_bl_s7
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
    #
    # Conversion is memoised over the 468 DISTINCT characters rather than run on
    # all 841 cells: the map is the same every time and 841 library calls per
    # page load for 468 answers is waste.
    #
    # If OpenCC is not available the conversion returns its input unchanged, so
    # the "simplified" grid would silently be the traditional one. That is the
    # kind of failure that looks like a data problem for weeks, so it is detected
    # and the view says so.
    simplify =
      if variant == "simp"
        if CharacterStandards.available?(:simplified)
          memo = {}
          ->(ch) { memo[ch] ||= CharacterStandards.convert(ch, :simplified).to_s }
        else
          @simplification_unavailable = true
          ->(ch) { ch }
        end
      else
        ->(ch) { ch }
      end

    indexed = @grid.xuanji_cells.index_by { |c| [c.x, c.y] }
    payload = []
    @grid.height.times do |y|
      @grid.width.times do |x|
        c = indexed.fetch([x, y])
        # A conversion that returned more than one character would change the
        # cell count and destroy the figure, so the original is kept and the
        # view is told. 29x29 is not negotiable.
        converted = simplify.call(c.char)
        if converted.length != 1
          converted = c.char
          @simplification_unavailable = true
        end
        payload << { x: x, y: y, char: converted, color: c.color }
      end
    end

    @cells_json = payload.to_json
    # @variant is set at the top, where the variant is decided.
  end

  # Copies colour classes from the traditional grid to the simplified grid.
  # This is important for Kang's colour-dependent reading rules.
  def sync_colors
    # We mirror the show action's variant selection so the button can be a simple POST
    # without needing a grid id.
    variant = params[:variant].in?(%w[trad simp]) ? params[:variant] : "simp"
    grid = XuanjiGrid.find_by!(variant: variant)
    unless grid.variant.to_s == "simp"
      render json: { ok: false, error: I18n.t("fun.xuanji.errors.sync_simplified_only") }, status: :unprocessable_entity
      return
    end

    trad = XuanjiGrid.find_by(name: grid.name, variant: :trad)
    unless trad
      render json: { ok: false, error: I18n.t("fun.xuanji.errors.no_matching_traditional_grid") }, status: :not_found
      return
    end

    Xuanji::SyncColors.call(trad:, simp: grid)
    render json: { ok: true }
  end

  # Does the reading on screen rhyme, and by whose rhyme book?
  #
  # 康萬民 explains his own count in terms of rhyme — 余用古韻而讀益多也 — so
  # rhyme is the filter that decides whether a path through the grid is a poem
  # at all. A reader that traces a path without saying whether it rhymes is
  # answering half the question.
  #
  # Params:  lines: ["...", "..."]
  # Returns: the shape Xuanji::RhymeCheck#call produces, with `ok`.
  def rhyme
    lines = Array(params[:lines]).map(&:to_s)
    render json: { ok: true }.merge(Xuanji::RhymeCheck.new(lines: lines).call)
  rescue StandardError => e
    render json: { ok: false, error: "#{e.class}: #{e.message}" }, status: :unprocessable_entity
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

    # VARIANT FORMS GET THE STANDARD FORM'S READING
    # ---------------------------------------------
    # The grid uses the glyph the 四庫 woodblock cuts, and Unihan indexes the
    # standard form. 㴱 had no kMandarin and came back as the bare character 㴱
    # where every neighbour had a romanisation, which reads as a gap in the data
    # and is not one: 㴱 and 深 are one character written two ways, and 深 has
    # shēn. Eighteen of the square's glyphs are in that position.
    #
    # Xuanji::RhymeCheck::VARIANTS already maps each of them to the form the
    # reference data indexes, and it was built by MEASURING which target is
    # actually present rather than by picking the canonical-looking one. So it is
    # reused here instead of a second map — one table, two uses.
    #
    # The variant is a FALLBACK, never a substitution: a character Unihan knows
    # is always answered by its own row. Mapping first would lose readings the
    # literal glyph has and the standard form does not.
    variants = Xuanji::RhymeCheck::VARIANTS
    fallback_for = chars.to_h { |ch| [ch, variants[ch]] }.compact
    chars |= fallback_for.values

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

        # Literal first, variant only where the literal has nothing.
        fallback_for.each do |chr, alt|
          next if reading_by_chr[chr].present?

          alt_reading = reading_by_chr[alt]
          reading_by_chr[chr] = alt_reading if alt_reading.present?
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
  # auto_sync_colors_if_needed! was here. It copied the colours from the
  # traditional grid onto the simplified one when the latter looked unpainted,
  # and it existed only because there WERE two stored grids. `show` now loads
  # one grid and converts at display time, so there is nothing to sync and
  # nothing for this to do.
  #
  # The sync_colors endpoint above is left in place: it is a route that may be
  # linked or scripted, it still works against a simp record if one exists, and
  # it fails with its own message if one does not. Removing a public endpoint is
  # not a decision to make silently inside a refactor.
end
