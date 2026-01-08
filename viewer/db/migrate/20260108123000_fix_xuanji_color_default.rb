class FixXuanjiColorDefault < ActiveRecord::Migration[8.1]
  # The xuanji_cells.color column is an enum (see XuanjiCell.color).
  # The original migration accidentally set a default of 9, which is not a valid enum value.
  # That makes newly-created cells effectively "uncoloured" (nil), breaking Kang's colour-based rules.
  def up
    # XuanjiCell.colors[:none] would be ideal, but models are not guaranteed to load in migrations.
    valid_max = 5
    none_value = 5

    change_column_default :xuanji_cells, :color, from: 9, to: none_value

    # Normalise existing bad values (NULL or out-of-range) to :none.
    execute <<~SQL
      UPDATE xuanji_cells
      SET color = #{none_value}
      WHERE color IS NULL OR color < 0 OR color > #{valid_max}
    SQL
  end

  def down
    change_column_default :xuanji_cells, :color, from: 5, to: 9
  end
end
