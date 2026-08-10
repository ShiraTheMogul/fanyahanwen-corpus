# frozen_string_literal: true

class CharacterStructure < ApplicationRecord
  belongs_to :character_codepoint
  has_many :components,
           -> { order(:preorder_index) },
           class_name: "CharacterStructureComponent",
           dependent: :destroy,
           inverse_of: :character_structure

  validates :system, :expression, :normalized_expression, :source, presence: true


  def glyph
    character_codepoint.chr
  end
end
