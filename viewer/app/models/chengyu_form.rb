# frozen_string_literal: true

class ChengyuForm < ApplicationRecord
  STANDARD_HAN_LENGTH = 4
  HARD_SCRIPT_CLASSES = %w[han han_with_punctuation].freeze

  belongs_to :chengyu, inverse_of: :forms
  belongs_to :first_character_codepoint, class_name: "CharacterCodepoint", optional: true
  belongs_to :last_character_codepoint, class_name: "CharacterCodepoint", optional: true

  has_many :form_characters, class_name: "ChengyuFormCharacter", dependent: :delete_all, inverse_of: :chengyu_form
  has_many :character_codepoints, through: :form_characters
  has_many :attestations, class_name: "ChengyuAttestation", dependent: :delete_all, inverse_of: :chengyu_form
  has_many :readings, class_name: "ChengyuReading", dependent: :delete_all, inverse_of: :chengyu_form
  has_many :senses, class_name: "ChengyuSense", dependent: :delete_all, inverse_of: :chengyu_form
  has_many :etymologies, class_name: "ChengyuEtymology", dependent: :delete_all, inverse_of: :chengyu_form
  has_many :provenances, class_name: "ChengyuProvenance", dependent: :delete_all, inverse_of: :chengyu_form
  has_many :corpus_occurrences, class_name: "ChengyuCorpusOccurrence", dependent: :delete_all, inverse_of: :chengyu_form

  validates :source_form_id, presence: true, uniqueness: true
  validates :form_text, :game_key, :script_class, presence: true

  scope :standard_game_pool, -> {
    where(is_strict_han: true, han_character_count: STANDARD_HAN_LENGTH)
      .where.not(first_character_codepoint_id: nil, last_character_codepoint_id: nil)
  }

  scope :hard_game_pool, -> {
    where(script_class: HARD_SCRIPT_CLASSES)
      .where("han_character_count >= ?", STANDARD_HAN_LENGTH)
      .where.not(first_character_codepoint_id: nil, last_character_codepoint_id: nil)
  }

  def self.game_pool(mode)
    mode.to_s == "hard" ? hard_game_pool : standard_game_pool
  end

  def compound?
    han_character_count.to_i > STANDARD_HAN_LENGTH || contains_punctuation?
  end

  def first_character
    game_key.to_s.each_char.first || first_character_codepoint&.chr
  end

  def last_character
    game_key.to_s[-1] || last_character_codepoint&.chr
  end
end
