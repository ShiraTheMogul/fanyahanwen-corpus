class DictionaryEntryBlock < ApplicationRecord
  belongs_to :dictionary_entry

  validates :position, presence: true, uniqueness: { scope: :dictionary_entry_id }
  validates :kind, :text, presence: true
end
