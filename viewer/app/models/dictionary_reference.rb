class DictionaryReference < ApplicationRecord
  belongs_to :dictionary_entry

  validates :position, presence: true, uniqueness: { scope: :dictionary_entry_id }
  validates :source_kind, :source_label, :source_path, :source_file, :raw_sha256, presence: true
end
