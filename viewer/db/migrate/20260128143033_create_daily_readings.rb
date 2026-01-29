class CreateDailyReadings < ActiveRecord::Migration[8.1]
  def change
    create_table :daily_readings do |t|
      t.string  :series_key,  null: false
      t.string  :mother,      null: false
      t.string  :subgroup,    null: false
      t.string  :title,       null: false
      t.integer :order_index, null: false
      t.text    :path,        null: false
      t.boolean :has_text,    null: false, default: true

      t.timestamps
    end

    add_index :daily_readings, [:series_key, :order_index], unique: true
    add_index :daily_readings, [:series_key, :has_text, :order_index]
  end
end
