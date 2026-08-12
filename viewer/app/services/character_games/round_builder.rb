# frozen_string_literal: true

module CharacterGames
  class RoundBuilder
    IDS_SAMPLE_MULTIPLIER = 8
    IDS_POINT_BATCH_SIZE = 500
    IDS_POINT_ATTEMPTS = 8

    def ids_rounds(limit: 20)
      scope = CharacterStructure.where(system: "ids", leaf_count: 2..8)
      rows = sampled_ids_rows(scope, target: limit * IDS_SAMPLE_MULTIPLIER)
        .select { |row| row.components.all? { |component| component.component_codepoint.present? } }
        .shuffle

      selected_groups = rows.group_by(&:character_codepoint_id).values.first(limit)
      character_ids = selected_groups.map { |structures| structures.first.character_codepoint_id }

      # One association-aware query supplies every IDS expression needed for the
      # selected characters. This avoids one query per round after sampling.
      all_structures_by_character = CharacterStructure
        .where(character_codepoint_id: character_ids, system: "ids")
        .includes(:components)
        .to_a
        .group_by(&:character_codepoint_id)

      selected_groups.map do |structures|
        sample = structures.first
        character = sample.character_codepoint
        all_structures = all_structures_by_character.fetch(character.id, structures)

        {
          glyph: character.chr,
          codepoint: "U+#{character.codepoint.to_s(16).upcase}",
          expressions: all_structures.map(&:normalized_expression).uniq,
          components: sample.components.map(&:component),
          top_level_operator: sample.top_level_operator
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

    private

    # The first performance pass replaced ORDER BY RANDOM() with random range
    # scans. On the production-sized SQLite database those range scans were even
    # slower because SQLite still had to walk forward looking for rows that met
    # the IDS filters. Instead, generate random primary keys in Ruby and ask
    # SQLite for those exact rows. INTEGER PRIMARY KEY lookups are bounded point
    # lookups; no global sort and no unbounded range walk is needed.
    def sampled_ids_rows(scope, target:)
      min_id = CharacterStructure.order(:id).limit(1).pick(:id)
      max_id = CharacterStructure.order(id: :desc).limit(1).pick(:id)
      return [] unless min_id && max_id

      rows_by_id = {}

      IDS_POINT_ATTEMPTS.times do
        break if rows_by_id.length >= target

        ids = Array.new(IDS_POINT_BATCH_SIZE) { rand(min_id..max_id) }.uniq
        scope
          .where(id: ids)
          .includes(:character_codepoint, :components)
          .to_a
          .each { |row| rows_by_id[row.id] = row }
      end

      # A very sparse ID range can occasionally yield fewer rows than requested.
      # Keep the fallback bounded: one small forward scan from the beginning,
      # used only to top up the random point sample rather than as the normal path.
      if rows_by_id.length < target
        scope
          .order(:id)
          .limit(target - rows_by_id.length)
          .includes(:character_codepoint, :components)
          .each { |row| rows_by_id[row.id] ||= row }
      end

      rows_by_id.values
    end
  end
end
