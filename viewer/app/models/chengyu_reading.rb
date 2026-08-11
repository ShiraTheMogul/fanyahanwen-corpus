# frozen_string_literal: true

class ChengyuReading < ApplicationRecord
  belongs_to :chengyu, inverse_of: :readings
  belongs_to :chengyu_form, inverse_of: :readings

  validates :source_reading_id, presence: true, uniqueness: true
  validates :reading, presence: true
end
