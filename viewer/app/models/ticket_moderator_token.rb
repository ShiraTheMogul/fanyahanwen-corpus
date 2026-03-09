class TicketModeratorToken < ApplicationRecord
  SCOPES = %w[review_only apply_patch admin].freeze

  validates :name, presence: true
  validates :scope, inclusion: { in: SCOPES }
  validates :token_digest, presence: true, uniqueness: true

  def revoked?
    revoked_at.present?
  end
end
