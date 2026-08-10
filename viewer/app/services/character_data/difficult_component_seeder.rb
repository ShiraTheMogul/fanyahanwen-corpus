# frozen_string_literal: true

module CharacterData
  # Register the zi.tools-style difficult-component palette in the canonical
  # CharacterCodepoint registry and expose each lookup membership on the
  # character's ordinary dictionary page.
  #
  # The structured grouping itself lives in Ids::DifficultComponents. The
  # CharacterProperty row is deliberately presentation/provenance metadata;
  # IDS search never reads it, so it cannot contaminate structural matching.
  class DifficultComponentSeeder
    SOURCE = "zi.tools Difficult Components"
    FIELD = "ids_difficult_component_lookup"

    Result = Struct.new(:memberships, :characters, :created_characters, :properties, keyword_init: true)

    def seed
      entries = Ids::DifficultComponents.entries
      unique_glyphs = entries.map(&:glyph).uniq
      created_characters = 0
      properties = 0

      ActiveRecord::Base.transaction do
        rows_by_glyph = unique_glyphs.to_h do |glyph|
          row = CodepointResolver.resolve_glyph(glyph)
          created_characters += 1 if row.previously_new_record?
          [glyph, row]
        end

        entries.each do |entry|
          row = rows_by_glyph.fetch(entry.glyph)
          property = CharacterProperty.find_or_create_by!(
            character_codepoint: row,
            source: SOURCE,
            field: FIELD,
            value: display_membership(entry)
          )
          properties += 1 if property.previously_new_record?
        end
      end

      Result.new(
        memberships: entries.length,
        characters: unique_glyphs.length,
        created_characters: created_characters,
        properties: properties
      )
    end

    private

    def display_membership(entry)
      count = entry.stroke_count.to_s
      strokes = count == "1" ? "1 stroke" : "#{count} strokes"
      "#{strokes} · #{entry.stroke_class_english} (#{entry.stroke_class_han})"
    end
  end
end
