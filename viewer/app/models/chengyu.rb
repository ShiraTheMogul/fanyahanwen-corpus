# frozen_string_literal: true

class Chengyu < ApplicationRecord
  has_many :forms, class_name: "ChengyuForm", dependent: :delete_all, inverse_of: :chengyu
  has_many :attestations, class_name: "ChengyuAttestation", dependent: :delete_all, inverse_of: :chengyu
  has_many :readings, class_name: "ChengyuReading", dependent: :delete_all, inverse_of: :chengyu
  has_many :senses, class_name: "ChengyuSense", dependent: :delete_all, inverse_of: :chengyu
  has_many :etymologies, class_name: "ChengyuEtymology", dependent: :delete_all, inverse_of: :chengyu
  has_many :provenances, class_name: "ChengyuProvenance", dependent: :delete_all, inverse_of: :chengyu
  has_many :corpus_occurrences, class_name: "ChengyuCorpusOccurrence", dependent: :delete_all, inverse_of: :chengyu
  has_many :form_relations, class_name: "ChengyuFormRelation", dependent: :delete_all, inverse_of: :chengyu

  validates :source_family_id, presence: true, uniqueness: true
  validates :display_form, presence: true

  def display_form_record
    forms.find { |form| form.is_display_form? } || forms.first
  end
end
