# frozen_string_literal: true

require "set"

namespace :unicode18 do
  desc "Seed CharacterCodepoint rows for the Unicode 18.0 Seal block (U+3D000..U+3FC3F)"
  task seed_seal_block: :environment do
    start_cp = 0x3D000
    end_cp   = 0x3FC3F
    batch    = 2_000
    now      = Time.current

    existing = CharacterCodepoint.where(codepoint: start_cp..end_cp).pluck(:codepoint).to_set

    rows = []
    inserted = 0

    start_cp.upto(end_cp) do |cp|
      next if existing.include?(cp)
      rows << { codepoint: cp, chr: [cp].pack("U"), created_at: now, updated_at: now }

      if rows.length >= batch
        CharacterCodepoint.insert_all(rows)
        inserted += rows.length
        rows.clear
      end
    end

    if rows.any?
      CharacterCodepoint.insert_all(rows)
      inserted += rows.length
    end

    puts "[unicode18] Seal block: inserted #{inserted} missing codepoints."
  end
end
