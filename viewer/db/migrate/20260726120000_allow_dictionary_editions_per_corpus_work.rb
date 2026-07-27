# frozen_string_literal: true

class AllowDictionaryEditionsPerCorpusWork < ActiveRecord::Migration[8.1]
  def up
    add_column :dictionary_works, :corpus_edition_id, :bigint unless column_exists?(:dictionary_works, :corpus_edition_id)

    if index_exists?(:dictionary_works, :corpus_work_id, name: "index_dictionary_works_on_corpus_work_id")
      remove_index :dictionary_works, name: "index_dictionary_works_on_corpus_work_id"
    end

    unless index_exists?(:dictionary_works, :corpus_work_id, name: "idx_dictionary_works_default_edition")
      add_index :dictionary_works,
        :corpus_work_id,
        unique: true,
        where: "corpus_edition_id IS NULL",
        name: "idx_dictionary_works_default_edition"
    end

    unless index_exists?(:dictionary_works, [:corpus_work_id, :corpus_edition_id], name: "idx_dictionary_works_corpus_edition")
      add_index :dictionary_works,
        [:corpus_work_id, :corpus_edition_id],
        unique: true,
        where: "corpus_edition_id IS NOT NULL",
        name: "idx_dictionary_works_corpus_edition"
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "Dictionary editions may now share a corpus_work_id; collapsing them automatically would discard data."
  end
end
