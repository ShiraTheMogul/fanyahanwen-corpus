# frozen_string_literal: true

class LaoguoyinReading < ApplicationRecord
  belongs_to :character_codepoint

  validates :laoguoyin, presence: true
  validates :source, presence: true
end

