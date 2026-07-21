class DictionaryReading < ApplicationRecord
  belongs_to :dictionary_entry

  validates :position, presence: true, uniqueness: { scope: :dictionary_entry_id }
  validates :kind, :raw_value, presence: true
end
