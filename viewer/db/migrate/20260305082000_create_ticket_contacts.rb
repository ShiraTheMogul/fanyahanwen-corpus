class CreateTicketContacts < ActiveRecord::Migration[8.1]
  def change
    create_table :ticket_contacts do |t|
      t.references :edit_ticket, null: false, foreign_key: true, index: { unique: true }

      # Encrypted contact fields (see app/models/ticket_contact.rb).
      t.text :name
      t.text :email
      t.text :notes

      t.datetime :expires_at, null: false

      t.timestamps
    end

    add_index :ticket_contacts, :expires_at
  end
end
