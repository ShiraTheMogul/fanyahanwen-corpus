class CreateEditTickets < ActiveRecord::Migration[8.1]
  def change
    create_table :edit_tickets do |t|
      t.string  :public_id, null: false
      t.string  :title, null: false
      t.text    :summary
      t.text    :reasoning

      # Where the edit request originated (e.g., corpus_viewer, dict, annotation_tool).
      t.string  :source, null: false

      # What the edit is targeting (e.g., a corpus file path, dictionary record id).
      t.string  :target_ref, null: false

      # Tags derived from source + content (stored, but generated server-side).
      t.json    :tags, null: false, default: []

      # Evidence links (preferred), plus optional file uploads.
      t.json    :evidence_links, null: false, default: []

      # Unified diff metadata (optional) – validated on submission.
      t.json    :diff_metadata, null: false, default: {}

      # Access control.
      t.string  :key_salt, null: false
      t.string  :key_digest, null: false
      t.datetime :key_generated_at, null: false

      # Lifecycle.
      t.string  :status, null: false, default: "open" # open, approved, rejected, closed
      t.datetime :closed_at

      t.timestamps
    end

    add_index :edit_tickets, :public_id, unique: true
    add_index :edit_tickets, :status
    add_index :edit_tickets, :source
    add_index :edit_tickets, :target_ref
    add_index :edit_tickets, :key_digest
  end
end
