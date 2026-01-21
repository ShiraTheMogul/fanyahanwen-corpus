# frozen_string_literal: true

class CharacterComponentMembership < ApplicationRecord
  belongs_to :character_codepoint

  validates :component_number, presence: true
end
