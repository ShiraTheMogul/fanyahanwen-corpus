# frozen_string_literal: true

module Xiangqi # 象棋
  class Board
	# Uses canonical stuff.
	# Black up top, red down the bottom.
	# Chu River is represented by a -----.
	# Taken from https://www.babelstone.co.uk/Fonts/XiangqiLayout.txt!
    INITIAL_ROWS = [
      "┏━━━━━━━━━┓",
      "┃🩫🩪🩩🩨🩧🩨🩩🩪🩫┃",
      "┃├┼┼┼┼┼┼┼┤┃",
      "┃├🩬┼┼┼┼┼🩬┤┃",
      "┃🩭┼🩭┼🩭┼🩭┼🩭┃",
      "┃└┴┴┴┴┴┴┴┘┃",
      "┃┌┬┬┬┬┬┬┬┐┃",
      "┃🩦┼🩦┼🩦┼🩦┼🩦┃",
      "┃├🩥┼┼┼┼┼🩥┤┃",
      "┃├┼┼┼┼┼┼┼┤┃",
      "┃🩤🩣🩢🩡🩠🩡🩢🩣🩤┃",
      "┗━━━━━━━━━┛"
    ].freeze

    def self.initial
      new(INITIAL_ROWS)
    end

    def initialize(rows)
      @rows = rows # floor is floor. ceiling is ceiling. sky is 天. 
    end

    def to_ascii # This is the whole point of the app basically - display in ASCII so fonts become "skins" whilst gamifying Literary Chinese.
      @rows.join("\n")
    end
  end
end
