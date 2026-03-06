class EditTicket < ApplicationRecord
  has_many_attached :evidence_files

  has_one :ticket_contact, dependent: :destroy
  has_many :ticket_audit_events, dependent: :destroy
  has_many :ticket_messages, dependent: :destroy

  STATUSES = %w[open approved rejected closed].freeze

  validates :public_id, presence: true, uniqueness: true
  validates :title, presence: true
  validates :source, presence: true
  validates :target_ref, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :key_salt, presence: true
  validates :key_digest, presence: true
  validates :key_generated_at, presence: true

  validate :evidence_links_shape

  def closed?
    status == "closed" || closed_at.present?
  end

  def close!
    update!(status: "closed", closed_at: Time.current)
  end

  private

  def evidence_links_shape
    return if evidence_links.blank?

    unless evidence_links.is_a?(Array)
      errors.add(:evidence_links, "must be an array")
      return
    end

    evidence_links.each do |link|
      unless link.is_a?(String)
        errors.add(:evidence_links, "must contain only strings")
        next
      end

      begin
        uri = URI.parse(link)
        unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
          errors.add(:evidence_links, "must be http(s) links")
        end
      rescue URI::InvalidURIError
        errors.add(:evidence_links, "contains an invalid URL")
      end
    end
  end
end
