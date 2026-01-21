class CreateKangxiRadicals < ActiveRecord::Migration[8.1]
  def change
    create_table :kangxi_radicals do |t|
      t.integer :number, null: false
      t.string :radical, null: false
      t.string :variants
      t.integer :stroke_count
      t.string :meaning
      t.string :colloquial_names
      t.string :pinyin
      t.string :sino_vietnamese
      t.string :japanese
      t.string :korean
      t.integer :frequency
      t.string :simplified
      t.string :examples

      t.timestamps
    end

    add_index :kangxi_radicals, :number, unique: true
    add_index :kangxi_radicals, :radical
  end
end
