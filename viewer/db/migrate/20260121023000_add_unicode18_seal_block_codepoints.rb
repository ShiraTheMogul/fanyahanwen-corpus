# frozen_string_literal: true

require "set"

class AddUnicode18SealBlockCodepoints < ActiveRecord::Migration[8.1]
  # Unicode 18.0 "Seal" block (accepted into the Pipeline):
  # U+3D000..U+3FC3F (11,328 code points)
  #
  # Sources:
  # - Unicode Pipeline entry "Seal (Seal block: 3D000..3FC3F)" (accepted 185-C3)
  # - UTC #185 minutes / recommendations (185-C3)
  #
  # This migration seeds CharacterCodepoint rows for that range if they are missing.
  #
  # It is safe to run multiple times: it only inserts missing codepoints.

  START_CODEPOINT = 0x3D000
  END_CODEPOINT   = 0x3FC3F
  BATCH_SIZE      = 2_000

  # Minimal model for migrations (avoid app-level validations/callbacks).
  class CharacterCodepoint < ActiveRecord::Base
    self.table_name = "character_codepoints"
  end

  def up
    now = Time.current

    existing = CharacterCodepoint.where(codepoint: START_CODEPOINT..END_CODEPOINT).pluck(:codepoint).to_set

    rows = []
    inserted = 0

    START_CODEPOINT.upto(END_CODEPOINT) do |cp|
      next if existing.include?(cp)

      rows << {
        codepoint: cp,
        chr: [cp].pack("U"),
        created_at: now,
        updated_at: now
      }

      if rows.length >= BATCH_SIZE
        CharacterCodepoint.insert_all(rows)
        inserted += rows.length
        rows.clear
      end
    end

    if rows.any?
      CharacterCodepoint.insert_all(rows)
      inserted += rows.length
    end

    say "Unicode 18.0 Seal block seed: inserted #{inserted} codepoints (missing only)."
  end

  def down
    CharacterCodepoint.where(codepoint: START_CODEPOINT..END_CODEPOINT).delete_all
  end
end
