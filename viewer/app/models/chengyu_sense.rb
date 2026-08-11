# frozen_string_literal: true

class ChengyuSense < ApplicationRecord
  belongs_to :chengyu, inverse_of: :senses
  belongs_to :chengyu_form, inverse_of: :senses

  validates :source_sense_id, presence: true, uniqueness: true
  validates :site, :pageid, :page_title, :plain_definition, presence: true
end
