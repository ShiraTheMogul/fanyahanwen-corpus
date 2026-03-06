class TicketContact < ApplicationRecord
  belongs_to :edit_ticket

  # Uses Active Record Encryption (Rails 7+). Requires:
  #   config.active_record.encryption.primary_key
  #   config.active_record.encryption.deterministic_key
  #   config.active_record.encryption.key_derivation_salt
  # in credentials or environment variables.
  encrypts :name
  encrypts :email
  encrypts :notes

  validates :expires_at, presence: true

  def expired?
    expires_at <= Time.current
  end
end
