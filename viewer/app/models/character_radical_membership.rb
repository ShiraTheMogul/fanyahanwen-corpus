class CharacterRadicalMembership < ApplicationRecord
  belongs_to :character_codepoint

  validates :radical_number, presence: true
  validates :additional_strokes, presence: true

  scope :for_radical, ->(n) { where(radical_number: Integer(n)) }
  scope :ordered, -> { order(:additional_strokes, :character_codepoint_id) }
end
