# frozen_string_literal: true

class CreateShuowenComponents < ActiveRecord::Migration[8.1]
  def change
    create_table :shuowen_components do |t|
      t.integer :number, null: false
      t.string :glyph, null: false

      t.timestamps
    end

    add_index :shuowen_components, :number, unique: true
    add_index :shuowen_components, :glyph
  end
end
