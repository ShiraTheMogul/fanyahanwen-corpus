# frozen_string_literal: true

class SupportStructuredDictionarySources < ActiveRecord::Migration[8.1]
  def change
    change_column_null :dictionary_entries, :corpus_document_id, true
    change_column_null :dictionary_entries, :source_line_start, true
    change_column_null :dictionary_entries, :source_line_end, true

    change_column_null :dictionary_references, :corpus_document_id, true
    change_column_null :dictionary_references, :line_start, true
    change_column_null :dictionary_references, :line_end, true

    add_column :dictionary_references, :source_record_key, :string
    add_index :dictionary_references, [:source_kind, :source_record_key], name: "idx_dictionary_refs_kind_record"
  end
end
