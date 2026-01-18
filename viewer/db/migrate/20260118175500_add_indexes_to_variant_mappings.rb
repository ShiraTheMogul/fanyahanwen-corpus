class AddIndexesToVariantMappings < ActiveRecord::Migration[8.1]
  def change
    # One mapping per variant codepoint makes lookups predictable.
    # This also makes bulk imports safe to re-run (insert-or-update).
    add_index :variant_mappings, :variant_codepoint, unique: true

    # Used for "give me all variants of this base" queries.
    add_index :variant_mappings, :base_codepoint
  end
end
