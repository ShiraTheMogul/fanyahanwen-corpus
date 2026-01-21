# frozen_string_literal: true

module Shuowen
  class ComponentSeeder
    # Seeds ShuowenComponent from a line-based glyph list.
    #
    # Repeatable pattern:
    # - Keep the canonical ordering in a text file under lib/data/
    # - Seed the reference table from it
    #
    # Safe to run multiple times:
    # - Deletes and recreates rows so ordering is always correct.
    def self.seed_from_file!(path)
      ShuowenComponent.delete_all

      lines = File.read(path, encoding: "UTF-8").split(/\R/)
      number = 0
      rows = []
      now = Time.current

      lines.each do |ln|
        glyph = ln.to_s.strip
        next if glyph.empty?

        # Defensive: if a line ever contains more than one glyph, keep it as-is.
        number += 1

        rows << { number: number, glyph: glyph, created_at: now, updated_at: now }
      end

      ShuowenComponent.insert_all(rows) if rows.any?
    end
  end
end
