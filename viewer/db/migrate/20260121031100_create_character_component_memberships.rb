# frozen_string_literal: true

class CreateCharacterComponentMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :character_component_memberships do |t|
      t.references :character_codepoint, null: false, foreign_key: true
      t.integer :component_number, null: false
      t.string :raw_token

      t.timestamps
    end

    add_index :character_component_memberships,
      [:component_number, :character_codepoint_id],
      name: "idx_ccm_component_ccid"

    add_index :character_component_memberships, :component_number
  end
end
