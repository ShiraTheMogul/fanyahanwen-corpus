class TicketAuditEvent < ApplicationRecord
  belongs_to :edit_ticket

  validates :action, presence: true
  validates :actor_type, presence: true
  validates :created_at, presence: true
end
