class CreateCharacterProperties < ActiveRecord::Migration[8.1]
  def change
    create_table :character_properties do |t|
      t.references :character_codepoint, null: false, foreign_key: true
      t.string :source, null: false
      t.string :field,  null: false
      t.text   :value,  null: false

      t.timestamps
    end

    add_index :character_properties,
      [:character_codepoint_id, :source, :field, :value],
      unique: true,
      name: "idx_character_properties_unique"
  end
end
