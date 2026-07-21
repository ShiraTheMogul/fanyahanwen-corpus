class DictionaryWork < ApplicationRecord
  has_many :dictionary_entries, dependent: :restrict_with_error
  has_many :dictionary_sections, dependent: :restrict_with_error

  validates :corpus_work_id, presence: true, uniqueness: true
  validates :title, :source_label, :parser_name, :parser_version, :import_fingerprint, presence: true
end
