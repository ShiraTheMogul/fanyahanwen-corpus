# frozen_string_literal: true

class CreateDictionaryCatalogueTables < ActiveRecord::Migration[8.1]
  def change
    create_table :dictionary_works do |t|
      t.bigint :corpus_work_id, null: false
      t.string :title, null: false
      t.string :edition_label
      t.string :source_label, null: false
      t.string :parser_name, null: false
      t.string :parser_version, null: false
      t.string :import_fingerprint, null: false
      t.integer :entry_count, null: false, default: 0
      t.integer :section_count, null: false, default: 0
      t.integer :reading_count, null: false, default: 0
      t.integer :entry_character_count, null: false, default: 0
      t.integer :reference_count, null: false, default: 0
      t.integer :group_count, null: false, default: 0
      t.datetime :imported_at, null: false
      t.json :import_metadata, null: false, default: {}
      t.timestamps
    end
    add_index :dictionary_works, :corpus_work_id, unique: true
    add_index :dictionary_works, :title
    add_index :dictionary_works, :import_fingerprint, unique: true

    create_table :dictionary_sections do |t|
      t.references :dictionary_work, null: false, foreign_key: true
      t.integer :sequence_number, null: false
      t.string :label, null: false
      t.string :tone
      t.integer :rhyme_number
      t.string :rhyme_label
      t.string :initial
      t.text :raw_heading
      t.json :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :dictionary_sections,
              [:dictionary_work_id, :sequence_number],
              unique: true,
              name: "idx_dictionary_sections_work_sequence"
    add_index :dictionary_sections,
              [:dictionary_work_id, :tone, :rhyme_label],
              name: "idx_dictionary_sections_work_tone_rhyme"

    create_table :dictionary_entries do |t|
      t.references :dictionary_work, null: false, foreign_key: true
      t.references :dictionary_section, null: false, foreign_key: true
      t.bigint :corpus_document_id, null: false
      t.integer :sequence_number, null: false
      t.integer :group_sequence
      t.integer :small_rime_number
      t.boolean :group_head, null: false, default: false
      t.string :headword, null: false
      t.text :definition
      t.text :raw_payload, null: false
      t.string :parser_name, null: false
      t.string :parser_version, null: false
      t.integer :source_line_start, null: false
      t.integer :source_line_end, null: false
      t.boolean :contains_unresolved_glyph, null: false, default: false
      t.boolean :review_required, null: false, default: false
      t.json :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :dictionary_entries,
              [:dictionary_work_id, :sequence_number],
              unique: true,
              name: "idx_dictionary_entries_work_sequence"
    add_index :dictionary_entries,
              [:dictionary_section_id, :group_sequence],
              name: "idx_dictionary_entries_section_group"
    add_index :dictionary_entries,
              [:corpus_document_id, :source_line_start],
              name: "idx_dictionary_entries_document_line"
    add_index :dictionary_entries, :headword

    create_table :dictionary_readings do |t|
      t.references :dictionary_entry, null: false, foreign_key: true
      t.integer :position, null: false, default: 1
      t.string :kind, null: false
      t.string :value
      t.string :raw_value, null: false
      t.json :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :dictionary_readings,
              [:dictionary_entry_id, :position],
              unique: true,
              name: "idx_dictionary_readings_entry_position"
    add_index :dictionary_readings, [:kind, :value]

    create_table :dictionary_entry_characters do |t|
      t.references :dictionary_entry, null: false, foreign_key: true
      t.references :character_codepoint, null: false, foreign_key: true
      t.integer :position, null: false
      t.string :role, null: false
      t.string :glyph, null: false
      t.timestamps
    end
    add_index :dictionary_entry_characters,
              [:dictionary_entry_id, :position],
              unique: true,
              name: "idx_dictionary_entry_characters_entry_position"
    add_index :dictionary_entry_characters, :glyph

    create_table :dictionary_references do |t|
      t.references :dictionary_entry, null: false, foreign_key: true
      t.integer :position, null: false, default: 1
      t.string :source_kind, null: false
      t.string :source_label, null: false
      t.bigint :corpus_work_id, null: false
      t.bigint :corpus_document_id, null: false
      t.text :source_path, null: false
      t.string :source_file, null: false
      t.integer :line_start, null: false
      t.integer :line_end, null: false
      t.string :raw_sha256, null: false
      t.json :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :dictionary_references,
              [:dictionary_entry_id, :position],
              unique: true,
              name: "idx_dictionary_references_entry_position"
    add_index :dictionary_references,
              [:corpus_document_id, :line_start],
              name: "idx_dictionary_references_document_line"
    add_index :dictionary_references, :raw_sha256
  end
end
