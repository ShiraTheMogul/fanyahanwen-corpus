# frozen_string_literal: true

module Xuanji
  # Load a 璇璣圖 from the plain text of the 四庫全書 edition.
  #
  # THE SQUARE IS 29 x 29 AND THE TEXT GIVES 840
  # --------------------------------------------
  # 康萬民's 凡例 is explicit: 是圖縱横八寸共計八百四十一言 — eight inches each
  # way, 841 characters. 841 = 29², and nothing else in the 采式 works at any
  # other size: 29 = 1 + 4x7, so lines on rows and columns 1, 8, 15, 22 and 29
  # cut the square into bands of 6, 13 and 6, which is precisely what the 采式
  # then measures (縱横皆六字 for the corners, 縱六字横十三字 for the sides).
  #
  # 晉書 says 八百四十字, the Siku editors repeat it, and the transmitted text
  # really does have 840 characters. The missing one is not missing: it is a
  # NOTE standing where a character should be —
  #
  #     「絃」字少最後一點
  #
  # "the character 絃, short of its final dot". The cell holds a glyph that is
  # 絃 written without its last stroke, which has no Unicode codepoint, so the
  # printers described it rather than setting it. Remove the whole note and the
  # count drops to 840; keep one character for it and the square closes.
  #
  # That is what SIKU_CELL_NOTES is for. 絃 stands in for the glyph, which is
  # honest — it is the character the note names — and `char` is a plain string
  # column, so if a better representation turns up it can simply be written in.
  #
  # The editorial apparatus that is NOT a cell is listed separately and
  # discarded: a cross-reference to the 采式, and the 〈〉 marks the Siku text
  # uses for line wrapping.
  #
  # ONE CHARACTER LIVES OUTSIDE THE BMP
  # -----------------------------------
  # 𤣥 (U+248E5) sits at row 21, column 17. Ruby's `each_char` counts code
  # points, so this class is fine; anything that reaches the grid through
  # JavaScript's `string[i]` or `.length` is not, and will be off by one for
  # the rest of that row. Worth knowing before trusting a count from elsewhere.
  class ImportPlaintext
    SIZE = 29
    EXPECTED = SIZE * SIZE

    # Notes the Siku printers set INSIDE the grid in place of a character, and
    # the character each one stands for. Each counts as exactly one cell.
    SIKU_CELL_NOTES = {
      "「絃」字少最後一點" => "絃"
    }.freeze

    # Editorial matter inside the grid that is not a cell at all.
    SIKU_APPARATUS = [
      "其采式詳讀法内"
    ].freeze

    # The Siku text wraps long runs in these; they carry no content.
    WRAPPERS = %w[〈 〉 ［ ］].freeze

    def initialize(grid:, plain:, default_color: :unknown)
      @grid = grid
      @plain = plain
      @default_color = default_color
    end

    def call!
      chars = normalize(@plain)

      unless chars.length == EXPECTED
        raise ArgumentError, count_complaint(chars.length)
      end

      ApplicationRecord.transaction do
        @grid.update!(width: SIZE, height: SIZE)
        @grid.xuanji_cells.delete_all

        chars.each_with_index do |ch, i|
          @grid.xuanji_cells.create!(
            x: i % SIZE,
            y: i / SIZE,
            char: ch,
            color: @default_color
          )
        end
      end

      @grid
    end

    private

    # A count that is nearly right is almost always one of two things, and
    # saying which saves the next person the hour it took to find them.
    def count_complaint(got)
      message = +"Expected #{EXPECTED} characters (#{SIZE}x#{SIZE}), got #{got}."

      if got == EXPECTED - 1
        message << " One short is the usual shape of this: the 四庫 text sets a"
        message << " NOTE where one cell should be — 「絃」字少最後一點 — and"
        message << " dropping it entirely leaves 840, which is the figure 晉書"
        message << " gives. See SIKU_CELL_NOTES."
      elsif got == EXPECTED + 1
        message << " One over is usually a byte-order mark: U+FEFF is not"
        message << " whitespace to Ruby, so a UTF-8-with-BOM file carries one"
        message << " extra character. `normalize` strips it, so check the text"
        message << " has not been wrapped in something else as well."
      elsif got > EXPECTED
        message << " More than expected usually means the 采式 cross-reference"
        message << " or a 〈〉 wrapper was counted as cells. See SIKU_APPARATUS."
      end

      message
    end

    def normalize(text)
      s = text.dup

      # A byte-order mark FIRST, because it is not whitespace and nothing
      # below will catch it.
      #
      # U+FEFF is ZERO WIDTH NO-BREAK SPACE, and Ruby matches it with neither
      # \\s nor [[:space:]]. A grid saved as UTF-8 with BOM — which is how
      # every Han-bearing text file in this repository is saved — therefore
      # arrives with one extra character at the front. The count comes to 842;
      # and if the count were not checked, every cell would be shifted by one
      # and 絃 would land where 賤 belongs. That is what happened the first
      # time this ran against a BOM'd file, and it is the same hazard as the
      # YAML one: a BOM is invisible and changes the parse.
      s.delete!("\uFEFF")

      # The cell notes first, because they must survive as one character each
      # and the apparatus strip below would otherwise eat part of them.
      SIKU_CELL_NOTES.each { |note, stands_for| s.gsub!(note, stands_for) }
      SIKU_APPARATUS.each { |note| s.gsub!(note, "") }
      WRAPPERS.each { |mark| s.gsub!(mark, "") }

      # Whitespace of every kind, including the ideographic space the Siku text
      # indents with.
      s.gsub!(/[[:space:]　]+/, "")

      s.each_char.to_a
    end
  end
end
