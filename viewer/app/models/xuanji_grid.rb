class XuanjiGrid < ApplicationRecord
  has_many :xuanji_cells, dependent: :destroy

  validates :name, presence: true
  validates :variant, inclusion: { in: %w[trad simp] }
  validates :width, :height, numericality: { greater_than: 0 }
end
