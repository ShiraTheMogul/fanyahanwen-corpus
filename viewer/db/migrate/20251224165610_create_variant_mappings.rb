class CreateVariantMappings < ActiveRecord::Migration[8.1]
  def change
    create_table :variant_mappings do |t|
      t.integer :variant_codepoint
      t.integer :base_codepoint
      t.string :source

      t.timestamps
    end
  end
end
