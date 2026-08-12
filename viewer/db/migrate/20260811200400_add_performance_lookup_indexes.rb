# frozen_string_literal: true

class AddPerformanceLookupIndexes < ActiveRecord::Migration[8.1]
  def change
    add_index :character_structure_components,
              %i[component character_structure_id],
              name: "idx_structure_components_component_structure",
              if_not_exists: true

    add_index :character_input_codes,
              %i[system_id kind],
              name: "idx_character_input_codes_system_kind",
              if_not_exists: true
  end
end
