class CreateXuanjiGrids < ActiveRecord::Migration[8.1]
  def change
    create_table :xuanji_grids do |t|
      t.string  :name, null: false
      t.string  :variant, null: false, default: "trad" # trad|simp
      t.integer :width, null: false, default: 29
      t.integer :height, null: false, default: 29
      t.text    :notes

      t.timestamps
    end

    add_index :xuanji_grids, [:name, :variant], unique: true
  end
end
