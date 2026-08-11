# frozen_string_literal: true

class ChengyuFormCharacter < ApplicationRecord
  belongs_to :chengyu_form, inverse_of: :form_characters
  belongs_to :character_codepoint

  validates :glyph, presence: true
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
