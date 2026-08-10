# frozen_string_literal: true

class CharacterInputCode < ApplicationRecord
  belongs_to :character_codepoint

  validates :system_id, :code, :kind, :source, presence: true

  scope :for_system, ->(system_id) { where(system_id: system_id.to_s) }

  def glyph
    character_codepoint.chr
  end
end
