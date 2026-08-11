# frozen_string_literal: true

class ChengyuCorpusOccurrence < ApplicationRecord
  belongs_to :chengyu, inverse_of: :corpus_occurrences
  belongs_to :chengyu_form, inverse_of: :corpus_occurrences
  belongs_to :chengyu_provenance, inverse_of: :corpus_occurrences

  validates :document_path, :matched_text, presence: true
  validates :start_offset, :end_offset, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :end_after_start

  scope :for_document, ->(path) { where(document_path: path.to_s) }

  def anchor_id
    "chengyu-occurrence-#{id}"
  end

  def context_label
    [work_title.presence, document_title.presence].compact.uniq.join(" · ").presence || File.basename(document_path.to_s, ".txt")
  end

  private

  def end_after_start
    return if start_offset.nil? || end_offset.nil? || end_offset > start_offset

    errors.add(:end_offset, "must be after start_offset")
  end
end
