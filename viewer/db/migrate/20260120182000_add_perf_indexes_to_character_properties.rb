class AddPerfIndexesToCharacterProperties < ActiveRecord::Migration[8.1]
  def change
    # The character page does many "single field" lookups. Examples:
    #   - kCompatibilityVariant
    #   - kRSUnicode
    #   - kRSAdobe_Japan1_6
    #   - kangxi_gloss (sometimes without a source for older imports)
    #
    # We already have:
    #   idx_character_properties_unique
    #     (character_codepoint_id, source, field, value)
    # This index is great for de-duplication, but it is larger than needed for
    # the common lookups above because it includes the TEXT :value column.
    #
    # These smaller supporting indexes keep queries index-friendly as the table grows.

    add_index :character_properties,
              [:character_codepoint_id, :field],
              name: "index_character_properties_on_ccid_field"

    add_index :character_properties,
              [:character_codepoint_id, :source, :field],
              name: "index_character_properties_on_ccid_source_field"
  end
end
