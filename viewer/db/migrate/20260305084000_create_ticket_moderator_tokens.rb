class CreateTicketModeratorTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :ticket_moderator_tokens do |t|
      t.string :name, null: false
      t.string :scope, null: false, default: "review_only" # review_only, apply_patch

      # Only store digests (the plaintext token is shown once).
      t.string :token_digest, null: false

      t.datetime :revoked_at
      t.datetime :last_used_at

      t.timestamps
    end

    add_index :ticket_moderator_tokens, :token_digest, unique: true
    add_index :ticket_moderator_tokens, :revoked_at
    add_index :ticket_moderator_tokens, :scope
  end
end
