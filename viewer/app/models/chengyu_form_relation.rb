# frozen_string_literal: true

class ChengyuFormRelation < ApplicationRecord
  belongs_to :chengyu, inverse_of: :form_relations
  belongs_to :source_form, class_name: "ChengyuForm"
  belongs_to :target_form, class_name: "ChengyuForm"

  validates :source_relation_id, presence: true, uniqueness: true
  validates :relation_type, presence: true
end
