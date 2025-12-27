class CreateLaoguoyinReadings < ActiveRecord::Migration[8.1]
  def change
    create_table :laoguoyin_readings do |t|
      t.references :character_codepoint, null: false, foreign_key: true
      t.string :laoguoyin, null: false
      t.string :zhuyin
      t.string :ipa
      t.string :source, null: false
      t.timestamps
    end

    add_index :laoguoyin_readings,
              [:character_codepoint_id, :laoguoyin, :source],
              unique: true,
              name: "idx_laoguoyin_readings_unique"
  end
end
