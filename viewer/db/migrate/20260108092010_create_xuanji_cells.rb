class CreateXuanjiCells < ActiveRecord::Migration[8.1]
  def change
    create_table :xuanji_cells do |t|
      t.references :xuanji_grid, null: false, foreign_key: true
      t.integer :x, null: false
      t.integer :y, null: false
      t.string  :char, null: false
      t.integer :color, null: false, default: 9

      t.timestamps
    end

    add_index :xuanji_cells, [:xuanji_grid_id, :x, :y], unique: true
    add_index :xuanji_cells, [:xuanji_grid_id, :y]
    add_index :xuanji_cells, [:xuanji_grid_id, :color]
  end
end
