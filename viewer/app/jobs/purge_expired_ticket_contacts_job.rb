class PurgeExpiredTicketContactsJob < ApplicationJob
  queue_as :default

  def perform
    # Delete contact rows when:
    # - the ticket is closed, OR
    # - the contact expired.
    TicketContact.joins(:edit_ticket)
      .where("ticket_contacts.expires_at <= ? OR edit_tickets.status = ?", Time.current, "closed")
      .find_each(batch_size: 200) do |contact|
        contact.destroy!
      end
  end
end
