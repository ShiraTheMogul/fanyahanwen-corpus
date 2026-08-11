# frozen_string_literal: true

class ChengyuImport < ApplicationRecord
  validates :fingerprint, presence: true, uniqueness: true
  validates :imported_at, presence: true
end
