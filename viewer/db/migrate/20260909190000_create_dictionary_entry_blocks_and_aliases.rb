# frozen_string_literal: true

class CreateDictionaryEntryBlocksAndAliases < ActiveRecord::Migration[8.1]
  def change
    create_table :dictionary_entry_blocks do |t|
      t.references :dictionary_entry, null: false, foreign_key: true
      t.integer :position, null: false
      t.string :kind, null: false
      t.text :text, null: false
      t.json :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :dictionary_entry_blocks,
              [:dictionary_entry_id, :position],
              unique: true,
              name: "idx_dictionary_entry_blocks_position"
    add_index :dictionary_entry_blocks,
              [:dictionary_entry_id, :kind, :position],
              name: "idx_dictionary_entry_blocks_kind"

    create_table :dictionary_entry_aliases do |t|
      t.references :dictionary_entry, null: false, foreign_key: true
      t.integer :position, null: false
      t.string :kind, null: false
      t.string :form, null: false
      t.boolean :is_pua, null: false, default: false
      t.json :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :dictionary_entry_aliases,
              [:dictionary_entry_id, :position],
              unique: true,
              name: "idx_dictionary_entry_aliases_position"
    add_index :dictionary_entry_aliases,
              :form,
              name: "idx_dictionary_entry_aliases_form"
    add_index :dictionary_entry_aliases,
              [:dictionary_entry_id, :kind, :position],
              name: "idx_dictionary_entry_aliases_kind"
  end
end
