class CreateTicketAuditEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :ticket_audit_events do |t|
      t.references :edit_ticket, null: false, foreign_key: true

      # What happened.
      t.string :action, null: false

      # Who did it.
      t.string :actor_type, null: false # submitter, moderator_token, system
      t.bigint :actor_id
      t.string :actor_label

      # Extra details (never rendered as HTML).
      t.json :metadata, null: false, default: {}

      t.datetime :created_at, null: false
    end

    add_index :ticket_audit_events, :action
    add_index :ticket_audit_events, :created_at
  end
end
