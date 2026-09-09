class DictionaryEntryAlias < ApplicationRecord
  belongs_to :dictionary_entry

  validates :position, presence: true, uniqueness: { scope: :dictionary_entry_id }
  validates :kind, :form, presence: true
end
