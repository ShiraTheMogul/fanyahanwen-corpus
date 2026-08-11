class CharacterCodepoint < ApplicationRecord
  has_many :character_properties, dependent: :delete_all

  # Chengyu forms use the same project-wide scalar registry as the dictionary,
  # IDS, RIME input data, and transcription tools. No second character table is
  # introduced for the word-game layer.
  has_many :chengyu_form_characters, dependent: :delete_all
  has_many :chengyu_forms, through: :chengyu_form_characters
end
