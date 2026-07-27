class DictionaryWork < ApplicationRecord
  has_many :dictionary_entries, dependent: :restrict_with_error
  has_many :dictionary_sections, dependent: :restrict_with_error

  validates :corpus_work_id, presence: true
  validates :title, :source_label, :parser_name, :parser_version, :import_fingerprint, presence: true

  validates :corpus_work_id,
    uniqueness: { conditions: -> { where(corpus_edition_id: nil) } },
    if: -> { corpus_edition_id.nil? }

  validates :corpus_edition_id,
    uniqueness: { scope: :corpus_work_id },
    allow_nil: true

  validates :edition_label, presence: true, if: -> { corpus_edition_id.present? }
end
