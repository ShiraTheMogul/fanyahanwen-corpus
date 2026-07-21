class DictionaryEntry < ApplicationRecord
  belongs_to :dictionary_work
  belongs_to :dictionary_section

  has_many :dictionary_readings, dependent: :delete_all
  has_many :dictionary_entry_characters, dependent: :delete_all
  has_many :character_codepoints, through: :dictionary_entry_characters
  has_many :dictionary_references, dependent: :delete_all

  validates :sequence_number, presence: true, uniqueness: { scope: :dictionary_work_id }
  validates :headword, :raw_payload, :parser_name, :parser_version, presence: true
end
