# frozen_string_literal: true

class ChengyuSemanticRelation < ApplicationRecord
  belongs_to :source_chengyu, class_name: "Chengyu"
  belongs_to :source_form, class_name: "ChengyuForm"
  belongs_to :target_chengyu, class_name: "Chengyu", optional: true
  belongs_to :target_form, class_name: "ChengyuForm", optional: true

  validates :source_relation_id, presence: true, uniqueness: true
  validates :target_text, :relation_type, presence: true
end
