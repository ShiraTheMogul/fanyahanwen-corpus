# frozen_string_literal: true

class CreateChengyuCorpusOccurrences < ActiveRecord::Migration[8.1]
  def change
    create_table :chengyu_corpus_occurrences do |t|
      t.references :chengyu, null: false, foreign_key: { on_delete: :cascade }
      t.references :chengyu_form, null: false, foreign_key: { on_delete: :cascade }
      t.references :chengyu_provenance, null: false, foreign_key: { on_delete: :cascade }
      t.string :corpus_work_id
      t.string :corpus_document_id
      t.string :document_path, null: false
      t.string :work_title
      t.string :document_title
      t.integer :start_offset, null: false
      t.integer :end_offset, null: false
      t.string :matched_text, null: false
      t.timestamps
    end

    add_index :chengyu_corpus_occurrences,
              [:chengyu_id, :document_path, :start_offset, :end_offset],
              unique: true,
              name: "idx_chengyu_corpus_occurrence_unique"
    add_index :chengyu_corpus_occurrences,
              [:document_path, :start_offset],
              name: "idx_chengyu_corpus_occurrence_document"
  end
end
