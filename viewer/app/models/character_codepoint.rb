class CharacterCodepoint < ApplicationRecord
  has_many :character_properties, dependent: :delete_all
end
