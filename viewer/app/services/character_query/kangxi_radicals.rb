# frozen_string_literal: true

module CharacterQuery
  # The 214 Kangxi radicals, arranged by stroke count for the picker grid.
  #
  # Nothing here is a hardcoded table, and there is no new data file. Two facts
  # do all the work:
  #
  #  1. The Kangxi Radicals block is U+2F00 onwards, in radical order, so
  #     radical N is always U+2F00 + N - 1.
  #  2. Every character in that block has an NFKC mapping to its unified
  #     ideograph — ⾺ to 馬 — so the glyph to display is one call away. All 214
  #     resolve; none is left as the block symbol, which many fonts render
  #     poorly or not at all.
  #
  # The stroke count then comes from the corpus itself: the unified glyph's own
  # kTotalStrokes. This deliberately reports what the data says rather than
  # what a canonical table says, so the grid and the results agree. Where
  # Unihan and the traditional arrangement differ — 瓦, 鼎, 龜 are the usual
  # ones — the grid follows Unihan, because that is what a stroke search will
  # actually match.
  #
  # Arranged by stroke count because that is how a reader who does not know a
  # radical's name finds it, which is the same lookup skill
  # Ids::DifficultComponents is built around.
  module KangxiRadicals
    BLOCK_START = 0x2F00
    COUNT = 214

    module_function

    # [{ number:, symbol:, glyph:, strokes: }], radical 1 first.
    def all
      @all ||= (1..COUNT).map do |number|
        symbol = [BLOCK_START + number - 1].pack("U")
        glyph = symbol.unicode_normalize(:nfkc)
        { number: number, symbol: symbol, glyph: glyph, strokes: stroke_counts[glyph] }
      end
    end

    # [[strokes, [radical, ...]], ...], fewest strokes first. A radical whose
    # stroke count is missing from the corpus lands in a trailing nil group
    # rather than being dropped: better a radical with no number beside it than
    # a grid that quietly holds 213.
    def groups
      @groups ||= all.group_by { |radical| radical[:strokes] }
                     .sort_by { |strokes, _| [strokes.nil? ? 1 : 0, strokes.to_i] }
    end

    def find(number)
      number = number.to_i
      return nil unless number.between?(1, COUNT)

      all[number - 1]
    end

    # Two queries rather than one join, deliberately.
    #
    # Written as a join, SQLite drives it from character_properties: it picks
    # index_character_properties_on_source_field_value and sweeps all 102,998
    # kTotalStrokes rows to find the 214 wanted, and it keeps that plan even
    # when the join is written the other way round. Split in two, each half is
    # a covering-index seek on 214 keys — index_character_codepoints_on_chr,
    # then (character_codepoint_id, source, field). Measured on the live
    # corpus: 0.051s against 0.001s warm, 1.571s against 0.103s cold.
    #
    # Memoised, so this is paid once per process however many times the panel
    # renders.
    def stroke_counts
      @stroke_counts ||= begin
        glyphs = (1..COUNT).map { |number| [BLOCK_START + number - 1].pack("U").unicode_normalize(:nfkc) }

        ids = CharacterCodepoint.where(chr: glyphs).pluck(:chr, :id)
        glyph_by_id = ids.to_h { |chr, id| [id, chr] }

        CharacterProperty
          .where(character_codepoint_id: glyph_by_id.keys,
                 source: "Unihan_IRGSources", field: "kTotalStrokes")
          .pluck(:character_codepoint_id, :value)
          .each_with_object({}) do |(codepoint_id, value), acc|
            glyph = glyph_by_id[codepoint_id]
            # Unihan can carry several stroke counts for one character. The
            # first is the primary one, and it is what a stroke search matches.
            acc[glyph] = value.to_s.split.first.to_i if glyph
          end
      rescue StandardError
        # The grid is still usable without stroke headings. It must never be
        # the reason the panel fails to render.
        {}
      end
    end
  end
end
