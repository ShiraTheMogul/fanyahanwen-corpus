# frozen_string_literal: true

class ShuowenComponent < ApplicationRecord
  validates :number, presence: true, uniqueness: true
  validates :glyph, presence: true

  def display_label
    "#{number}. #{glyph}"
  end
end
