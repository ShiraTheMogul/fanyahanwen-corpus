# frozen_string_literal: true

class AddInitialToDictionaryEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :dictionary_entries, :initial, :string
    add_index :dictionary_entries,
              [:dictionary_work_id, :initial],
              name: "idx_dictionary_entries_work_initial"
  end
end
