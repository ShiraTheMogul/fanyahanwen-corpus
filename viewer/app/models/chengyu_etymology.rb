# frozen_string_literal: true

class ChengyuEtymology < ApplicationRecord
  belongs_to :chengyu, inverse_of: :etymologies
  belongs_to :chengyu_form, inverse_of: :etymologies

  validates :source_etymology_id, presence: true, uniqueness: true
  validates :site, :pageid, :page_title, presence: true
end
