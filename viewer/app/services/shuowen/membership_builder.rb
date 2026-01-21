# frozen_string_literal: true

module Shuowen
  class MembershipBuilder
    BATCH = 10_000
    DEFAULT_FIELD = "shuowen_category"

    # Rebuild CharacterComponentMembership from an existing Shuowen category property in character_properties.
    #
    # Expected:
    # - field: "shuowen_category"
    # - value: something like "目部" (we extract the first Han glyph as the component glyph)
    #
    # You can override:
    #   FIELD=shuowen_category SOURCE="Shuowen Jiezi"
    def self.rebuild!(field: nil, source: nil)
      CharacterComponentMembership.delete_all

      components = ShuowenComponent.order(:number).pluck(:number, :glyph)
      return { field: nil, source: nil, rows: 0, reason: "no_components" } if components.empty?

      glyph_to_number = components.map { |n, g| [g, n] }.to_h

      chosen_field = (field.presence || DEFAULT_FIELD).to_s
      chosen_source = source.presence

      scope = CharacterProperty.where(field: chosen_field)
      scope = scope.where(source: chosen_source) if chosen_source.present?

      return { field: chosen_field, source: chosen_source, rows: 0, reason: "no_rows_for_field" } unless scope.exists?

      rows = []
      now = Time.current
      inserted = 0

      scope.select(:id, :character_codepoint_id, :value).find_in_batches(batch_size: BATCH) do |batch|
        batch.each do |prop|
          ccid = prop.character_codepoint_id
          next if ccid.nil?

          raw = prop.value.to_s.strip
          next if raw.empty?

          # Typical values are like "目部". Grab first Han glyph.
          comp_glyph = raw[/\p{Han}/]
          next unless comp_glyph

          num = glyph_to_number[comp_glyph]
          next unless num

          rows << {
            character_codepoint_id: ccid,
            component_number: num,
            raw_token: raw,
            created_at: now,
            updated_at: now
          }
        end

        if rows.length >= BATCH
          CharacterComponentMembership.insert_all(rows)
          inserted += rows.length
          rows.clear
        end
      end

      if rows.any?
        CharacterComponentMembership.insert_all(rows)
        inserted += rows.length
      end

      { field: chosen_field, source: chosen_source, rows: inserted, reason: "ok" }
    end
  end
end
