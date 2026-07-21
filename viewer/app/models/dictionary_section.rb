class DictionarySection < ApplicationRecord
  belongs_to :dictionary_work
  has_many :dictionary_entries, dependent: :restrict_with_error

  validates :sequence_number, presence: true, uniqueness: { scope: :dictionary_work_id }
  validates :label, presence: true
end
