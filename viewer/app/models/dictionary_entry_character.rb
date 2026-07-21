class DictionaryEntryCharacter < ApplicationRecord
  belongs_to :dictionary_entry
  belongs_to :character_codepoint

  validates :position, presence: true, uniqueness: { scope: :dictionary_entry_id }
  validates :role, :glyph, presence: true
end
