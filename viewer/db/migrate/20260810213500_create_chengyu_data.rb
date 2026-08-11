# frozen_string_literal: true

class CreateChengyuData < ActiveRecord::Migration[8.1]
  def change
    create_table :chengyu_imports do |t|
      t.string :fingerprint, null: false
      t.datetime :imported_at, null: false
      t.string :source_path
      t.json :source_manifest, null: false, default: {}
      t.json :counts, null: false, default: {}
      t.timestamps
    end
    add_index :chengyu_imports, :fingerprint, unique: true

    create_table :chengyus do |t|
      t.string :source_family_id, null: false
      t.string :display_form, null: false
      t.json :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :chengyus, :source_family_id, unique: true
    add_index :chengyus, :display_form

    create_table :chengyu_forms do |t|
      t.references :chengyu, null: false, foreign_key: { on_delete: :cascade }
      t.string :source_form_id, null: false
      t.string :form_text, null: false
      t.string :game_key, null: false
      t.boolean :is_display_form, null: false, default: false
      t.string :script_class, null: false
      t.integer :codepoint_length, null: false
      t.integer :han_character_count, null: false
      t.boolean :is_strict_han, null: false, default: false
      t.boolean :contains_punctuation, null: false, default: false
      t.references :first_character_codepoint, null: true, foreign_key: { to_table: :character_codepoints }
      t.references :last_character_codepoint, null: true, foreign_key: { to_table: :character_codepoints }
      t.json :statuses, null: false, default: []
      t.json :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :chengyu_forms, :source_form_id, unique: true
    add_index :chengyu_forms, :form_text
    add_index :chengyu_forms, :game_key
    add_index :chengyu_forms,
              [:first_character_codepoint_id, :han_character_count],
              name: "idx_chengyu_forms_first_han_count"
    add_index :chengyu_forms,
              [:last_character_codepoint_id, :han_character_count],
              name: "idx_chengyu_forms_last_han_count"
    add_index :chengyu_forms,
              [:chengyu_id, :is_display_form],
              name: "idx_chengyu_forms_family_display"

    create_table :chengyu_form_characters do |t|
      t.references :chengyu_form, null: false, foreign_key: { on_delete: :cascade }
      t.references :character_codepoint, null: false, foreign_key: true
      t.string :glyph, null: false
      t.integer :position, null: false
      t.timestamps
    end
    add_index :chengyu_form_characters,
              [:chengyu_form_id, :position],
              unique: true,
              name: "idx_chengyu_form_chars_position"
    add_index :chengyu_form_characters,
              [:character_codepoint_id, :chengyu_form_id],
              name: "idx_chengyu_form_chars_lookup"

    create_table :chengyu_attestations do |t|
      t.references :chengyu, null: false, foreign_key: { on_delete: :cascade }
      t.references :chengyu_form, null: false, foreign_key: { on_delete: :cascade }
      t.string :source_attestation_id, null: false
      t.string :site, null: false
      t.bigint :pageid, null: false
      t.string :page_title, null: false
      t.string :entry_language_tag
      t.string :entry_language_source
      t.string :attestation_kind
      t.json :source_keys, null: false, default: []
      t.json :source_categories, null: false, default: []
      t.json :categories, null: false, default: []
      t.bigint :revision_id
      t.datetime :revision_timestamp
      t.string :revision_sha1
      t.text :url
      t.boolean :has_definition_evidence, null: false, default: false
      t.json :source_gaps, null: false, default: []
      t.timestamps
    end
    add_index :chengyu_attestations, :source_attestation_id, unique: true, name: "idx_chengyu_attestations_source_id"
    add_index :chengyu_attestations, [:chengyu_id, :entry_language_tag], name: "idx_chengyu_attestations_family_lang"
    add_index :chengyu_attestations, [:site, :pageid], name: "idx_chengyu_attestations_page"

    create_table :chengyu_readings do |t|
      t.references :chengyu, null: false, foreign_key: { on_delete: :cascade }
      t.references :chengyu_form, null: false, foreign_key: { on_delete: :cascade }
      t.string :source_reading_id, null: false
      t.text :reading, null: false
      t.string :language_tag
      t.string :language_label
      t.string :system
      t.string :system_label
      t.string :site
      t.bigint :pageid
      t.string :page_title
      t.string :source_template
      t.string :source_type_code
      t.text :url
      t.timestamps
    end
    add_index :chengyu_readings, :source_reading_id, unique: true, name: "idx_chengyu_readings_source_id"
    add_index :chengyu_readings, [:chengyu_id, :language_tag], name: "idx_chengyu_readings_family_lang"
    add_index :chengyu_readings, [:chengyu_form_id, :system], name: "idx_chengyu_readings_form_system"

    create_table :chengyu_senses do |t|
      t.references :chengyu, null: false, foreign_key: { on_delete: :cascade }
      t.references :chengyu_form, null: false, foreign_key: { on_delete: :cascade }
      t.string :source_sense_id, null: false
      t.string :site, null: false
      t.bigint :pageid, null: false
      t.string :page_title, null: false
      t.string :entry_language_tag
      t.string :definition_language_tag
      t.string :heading_path
      t.string :section_kind
      t.text :plain_definition, null: false
      t.text :raw_definition
      t.timestamps
    end
    add_index :chengyu_senses, :source_sense_id, unique: true, name: "idx_chengyu_senses_source_id"
    add_index :chengyu_senses, [:chengyu_id, :definition_language_tag], name: "idx_chengyu_senses_family_def_lang"

    create_table :chengyu_etymologies do |t|
      t.references :chengyu, null: false, foreign_key: { on_delete: :cascade }
      t.references :chengyu_form, null: false, foreign_key: { on_delete: :cascade }
      t.string :source_etymology_id, null: false
      t.string :site, null: false
      t.bigint :pageid, null: false
      t.string :page_title, null: false
      t.string :entry_language_tag
      t.string :definition_language_tag
      t.string :heading_path
      t.text :plain_text, null: false
      t.text :raw_wikitext
      t.timestamps
    end
    add_index :chengyu_etymologies, :source_etymology_id, unique: true, name: "idx_chengyu_etymologies_source_id"
    add_index :chengyu_etymologies, [:chengyu_id, :definition_language_tag], name: "idx_chengyu_etymologies_family_lang"

    create_table :chengyu_provenances do |t|
      t.references :chengyu, null: false, foreign_key: { on_delete: :cascade }
      t.references :chengyu_form, null: false, foreign_key: { on_delete: :cascade }
      t.string :source_provenance_id, null: false
      t.string :site, null: false
      t.bigint :pageid, null: false
      t.string :page_title, null: false
      t.string :source_category
      t.string :source_title
      t.text :url
      t.timestamps
    end
    add_index :chengyu_provenances, :source_provenance_id, unique: true, name: "idx_chengyu_provenances_source_id"
    add_index :chengyu_provenances, [:chengyu_id, :source_category], name: "idx_chengyu_provenances_family_category"

    create_table :chengyu_form_relations do |t|
      t.references :chengyu, null: false, foreign_key: { on_delete: :cascade }
      t.references :source_form, null: false, foreign_key: { to_table: :chengyu_forms, on_delete: :cascade }
      t.references :target_form, null: false, foreign_key: { to_table: :chengyu_forms, on_delete: :cascade }
      t.string :source_relation_id, null: false
      t.string :relation_type, null: false
      t.string :site
      t.bigint :pageid
      t.string :source_template
      t.string :cause
      t.text :raw_evidence
      t.string :merge_policy
      t.timestamps
    end
    add_index :chengyu_form_relations, :source_relation_id, unique: true, name: "idx_chengyu_form_relations_source_id"
    add_index :chengyu_form_relations, [:source_form_id, :target_form_id], name: "idx_chengyu_form_relations_pair"

    create_table :chengyu_semantic_relations do |t|
      t.references :source_chengyu, null: false, foreign_key: { to_table: :chengyus, on_delete: :cascade }
      t.references :source_form, null: false, foreign_key: { to_table: :chengyu_forms, on_delete: :cascade }
      t.references :target_chengyu, null: true, foreign_key: { to_table: :chengyus, on_delete: :nullify }
      t.references :target_form, null: true, foreign_key: { to_table: :chengyu_forms, on_delete: :nullify }
      t.string :source_relation_id, null: false
      t.string :target_text, null: false
      t.string :relation_type, null: false
      t.string :relation_language
      t.string :site
      t.bigint :pageid
      t.string :page_title
      t.string :source_template
      t.text :raw_definition
      t.string :merge_policy
      t.timestamps
    end
    add_index :chengyu_semantic_relations, :source_relation_id, unique: true, name: "idx_chengyu_semantic_relations_source_id"
    add_index :chengyu_semantic_relations, [:source_chengyu_id, :relation_type], name: "idx_chengyu_semantic_relations_source"
    add_index :chengyu_semantic_relations, :target_chengyu_id, name: "idx_chengyu_semantic_relations_target"
  end
end
