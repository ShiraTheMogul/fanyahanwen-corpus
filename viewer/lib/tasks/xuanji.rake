namespace :xuanji do
  desc "Sync colours from Traditional (trad) grid to Simplified (simp) grid by (x,y) coordinate"
  task sync_colors: :environment do
    trad = XuanjiGrid.find_by!(variant: "trad")
    simp = XuanjiGrid.find_by!(variant: "simp")

    trad_map = trad.xuanji_cells.index_by { |c| [c.x, c.y] }

    updated = 0
    simp.xuanji_cells.find_each do |c|
      src = trad_map[[c.x, c.y]]
      next unless src
      next if c.color == src.color

      c.update_column(:color, src.color)
      updated += 1
    end

    puts "✓ Colours synced by (x,y). Updated #{updated} cell(s)."
  end
end
