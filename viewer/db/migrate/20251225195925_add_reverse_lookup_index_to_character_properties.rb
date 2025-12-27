class AddReverseLookupIndexToCharacterProperties < ActiveRecord::Migration[8.1]
  def change
    add_index :character_properties, [:source, :field, :value],
              name: "index_character_properties_on_source_field_value"
  end
end
