class CreateTicketMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :ticket_messages do |t|
      t.references :edit_ticket, null: false, foreign_key: true
      t.text :body, null: false

      t.string :actor_type, null: false # submitter, moderator_token
      t.bigint :actor_id
      t.string :actor_label

      t.datetime :created_at, null: false
    end

    add_index :ticket_messages, :created_at
  end
end
