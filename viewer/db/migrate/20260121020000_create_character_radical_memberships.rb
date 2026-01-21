# frozen_string_literal: true

class CreateCharacterRadicalMemberships < ActiveRecord::Migration[7.1]
  # This migration must work across adapters (SQLite/MySQL/Postgres).
  # `algorithm: :concurrently` is Postgres-specific and will error on others,
  # so we avoid it here.

  def up
    create_table :character_radical_memberships do |t|
      t.references :character_codepoint, null: false, foreign_key: true
      t.integer :radical_number, null: false
      t.integer :additional_strokes, null: false
      t.string :raw_token
      t.timestamps
    end

    add_index :character_radical_memberships,
              [:radical_number, :additional_strokes, :character_codepoint_id],
              name: "idx_crm_radical_strokes_ccid"
  end

  def down
    drop_table :character_radical_memberships
  end
end
