# frozen_string_literal: true

class ChengyuProvenance < ApplicationRecord
  belongs_to :chengyu, inverse_of: :provenances
  belongs_to :chengyu_form, inverse_of: :provenances
  has_many :corpus_occurrences, class_name: "ChengyuCorpusOccurrence", dependent: :delete_all, inverse_of: :chengyu_provenance

  validates :source_provenance_id, presence: true, uniqueness: true
  validates :site, :pageid, :page_title, presence: true
end
