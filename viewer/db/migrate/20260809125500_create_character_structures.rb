# frozen_string_literal: true

class CreateCharacterStructures < ActiveRecord::Migration[8.1]
  def change
    create_table :character_structures do |t|
      t.references :character_codepoint, null: false, foreign_key: true
      t.string :system, null: false, default: "ids"
      t.text :expression, null: false
      t.text :normalized_expression, null: false
      t.string :top_level_operator
      t.text :component_signature
      t.text :operator_signature
      t.integer :leaf_count, null: false, default: 0
      t.string :source, null: false
      t.string :source_version
      t.string :source_level
      t.string :glyph_region
      t.json :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :character_structures, [:system, :normalized_expression], name: "idx_character_structures_expression"
    add_index :character_structures, [:character_codepoint_id, :system], name: "idx_character_structures_character_system"
    add_index :character_structures,
              [:character_codepoint_id, :system, :normalized_expression, :source, :source_level, :glyph_region],
              unique: true,
              name: "idx_character_structures_unique_source_expression"

    create_table :character_structure_components do |t|
      t.references :character_structure, null: false, foreign_key: true
      t.string :component, null: false
      t.integer :component_codepoint
      t.integer :depth, null: false, default: 0
      t.integer :preorder_index, null: false
      t.timestamps
    end

    add_index :character_structure_components, :component
    add_index :character_structure_components, :component_codepoint
    add_index :character_structure_components,
              [:character_structure_id, :preorder_index],
              unique: true,
              name: "idx_character_structure_components_position"
  end
end
