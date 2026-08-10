# frozen_string_literal: true

class CharacterStructureComponent < ApplicationRecord
  belongs_to :character_structure, inverse_of: :components

  validates :component, presence: true
  validates :preorder_index, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
