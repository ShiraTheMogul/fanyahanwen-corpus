# frozen_string_literal: true

module CharacterGames
  class RoundBuilder
    IDS_SAMPLE_MULTIPLIER = 8

    def ids_rounds(limit: 20)
      rows = CharacterStructure
        .where(system: "ids", leaf_count: 2..8)
        .includes(:character_codepoint, :components)
        .order(Arel.sql("RANDOM()"))
        .limit(limit * IDS_SAMPLE_MULTIPLIER)
        .to_a
        .select { |row| row.components.all? { |component| component.component_codepoint.present? } }

      rows.group_by(&:character_codepoint_id).values.first(limit).map do |structures|
        character = structures.first.character_codepoint
        all_structures = CharacterStructure
          .where(character_codepoint_id: character.id, system: "ids")
          .includes(:components)
          .to_a

        {
          glyph: character.chr,
          codepoint: "U+#{character.codepoint.to_s(16).upcase}",
          expressions: all_structures.map(&:normalized_expression).uniq,
          components: structures.first.components.map(&:component),
          top_level_operator: structures.first.top_level_operator
        }
      end
    end

    def component_rounds(limit: 24)
      Ids::DifficultComponents.entries
        .group_by(&:glyph)
        .values
        .sample(limit)
        .map do |entries|
          first = entries.first
          {
            glyph: first.glyph,
            codepoint: first.codepoint ? "U+#{first.codepoint.to_s(16).upcase}" : nil,
            answers: entries.map { |entry| { stroke_count: entry.stroke_count.to_s, stroke_class: entry.stroke_class } }
          }
        end
    end
  end
end
