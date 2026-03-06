module EditTickets
  class AuditLogger
    def self.log!(ticket:, action:, actor_type:, actor_id: nil, actor_label: nil, metadata: {})
      TicketAuditEvent.create!(
        edit_ticket: ticket,
        action: action,
        actor_type: actor_type,
        actor_id: actor_id,
        actor_label: actor_label,
        metadata: metadata,
        created_at: Time.current
      )
    end
  end
end
