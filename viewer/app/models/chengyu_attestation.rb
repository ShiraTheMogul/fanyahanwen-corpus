# frozen_string_literal: true

class ChengyuAttestation < ApplicationRecord
  SITE_LABELS = {
    "enwiktionary" => "English Wiktionary",
    "zhwiktionary" => "Chinese Wiktionary",
    "jawiktionary" => "Japanese Wiktionary",
    "kowiktionary" => "Korean Wiktionary"
  }.freeze

  belongs_to :chengyu, inverse_of: :attestations
  belongs_to :chengyu_form, inverse_of: :attestations

  validates :source_attestation_id, presence: true, uniqueness: true
  validates :site, :pageid, :page_title, presence: true

  def site_label
    SITE_LABELS.fetch(site, site)
  end
end
