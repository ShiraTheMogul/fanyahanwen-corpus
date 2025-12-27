class CreateCharacterCodepoints < ActiveRecord::Migration[8.1]
  def change
    create_table :character_codepoints do |t|
		t.integer :codepoint, null: false
		t.string  :chr, null: false
		
		t.timestamps
    end
	
	add_index :character_codepoints, :codepoint, unique: true
	add_index :character_codepoints, :chr
  end
end
