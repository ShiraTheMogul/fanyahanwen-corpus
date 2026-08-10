# frozen_string_literal: true

class CreateCharacterInputCodes < ActiveRecord::Migration[8.1]
  def change
    create_table :character_input_codes do |t|
      t.references :character_codepoint, null: false, foreign_key: true
      t.string :system_id, null: false
      t.string :code, null: false
      t.string :kind, null: false, default: "input"
      t.string :source, null: false
      t.string :source_version
      t.json :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :character_input_codes, [:system_id, :code], name: "idx_character_input_codes_lookup"
    add_index :character_input_codes,
              [:character_codepoint_id, :system_id, :code, :kind, :source],
              unique: true,
              name: "idx_character_input_codes_unique_source_code"
  end
end
