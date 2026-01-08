class XuanjiCell < ApplicationRecord
  belongs_to :xuanji_grid

  enum :color, {
    maroon: 0,  # #800000
    black:  1,  # #000000
    navy:   2,  # #000080
    olive:  3,  # #808000
    purple: 4,  # #6c3baa
    teal:   5,  # #008080
    unknown: 9
  }

  validates :x, :y, presence: true
  validates :char, presence: true
end
