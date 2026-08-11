# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_11_000000) do
  create_table "active_storage_attachments", force: :cascade do |t|
    t.integer "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.integer "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "character_codepoints", force: :cascade do |t|
    t.string "chr", null: false
    t.integer "codepoint", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["chr"], name: "index_character_codepoints_on_chr"
    t.index ["codepoint"], name: "index_character_codepoints_on_codepoint", unique: true
  end

  create_table "character_input_codes", force: :cascade do |t|
    t.integer "character_codepoint_id", null: false
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.string "kind", default: "input", null: false
    t.json "metadata", default: {}, null: false
    t.string "source", null: false
    t.string "source_version"
    t.string "system_id", null: false
    t.datetime "updated_at", null: false
    t.index ["character_codepoint_id", "system_id", "code", "kind", "source"], name: "idx_character_input_codes_unique_source_code", unique: true
    t.index ["character_codepoint_id"], name: "index_character_input_codes_on_character_codepoint_id"
    t.index ["system_id", "code"], name: "idx_character_input_codes_lookup"
  end

  create_table "character_properties", force: :cascade do |t|
    t.integer "character_codepoint_id", null: false
    t.datetime "created_at", null: false
    t.string "field", null: false
    t.string "source", null: false
    t.datetime "updated_at", null: false
    t.text "value", null: false
    t.index ["character_codepoint_id", "field"], name: "index_character_properties_on_ccid_field"
    t.index ["character_codepoint_id", "source", "field", "value"], name: "idx_character_properties_unique", unique: true
    t.index ["character_codepoint_id", "source", "field"], name: "index_character_properties_on_ccid_source_field"
    t.index ["character_codepoint_id"], name: "index_character_properties_on_character_codepoint_id"
    t.index ["source", "field", "value"], name: "index_character_properties_on_source_field_value"
  end

  create_table "character_structure_components", force: :cascade do |t|
    t.integer "character_structure_id", null: false
    t.string "component", null: false
    t.integer "component_codepoint"
    t.datetime "created_at", null: false
    t.integer "depth", default: 0, null: false
    t.integer "preorder_index", null: false
    t.datetime "updated_at", null: false
    t.index ["character_structure_id", "preorder_index"], name: "idx_character_structure_components_position", unique: true
    t.index ["character_structure_id"], name: "index_character_structure_components_on_character_structure_id"
    t.index ["component"], name: "index_character_structure_components_on_component"
    t.index ["component_codepoint"], name: "index_character_structure_components_on_component_codepoint"
  end

  create_table "character_structures", force: :cascade do |t|
    t.integer "character_codepoint_id", null: false
    t.text "component_signature"
    t.datetime "created_at", null: false
    t.text "expression", null: false
    t.string "glyph_region"
    t.integer "leaf_count", default: 0, null: false
    t.json "metadata", default: {}, null: false
    t.text "normalized_expression", null: false
    t.text "operator_signature"
    t.string "source", null: false
    t.string "source_level"
    t.string "source_version"
    t.string "system", default: "ids", null: false
    t.string "top_level_operator"
    t.datetime "updated_at", null: false
    t.index ["character_codepoint_id", "system", "normalized_expression", "source", "source_level", "glyph_region"], name: "idx_character_structures_unique_source_expression", unique: true
    t.index ["character_codepoint_id", "system"], name: "idx_character_structures_character_system"
    t.index ["character_codepoint_id"], name: "index_character_structures_on_character_codepoint_id"
    t.index ["system", "normalized_expression"], name: "idx_character_structures_expression"
  end

  create_table "chengyu_attestations", force: :cascade do |t|
    t.string "attestation_kind"
    t.json "categories", default: [], null: false
    t.integer "chengyu_form_id", null: false
    t.integer "chengyu_id", null: false
    t.datetime "created_at", null: false
    t.string "entry_language_source"
    t.string "entry_language_tag"
    t.boolean "has_definition_evidence", default: false, null: false
    t.string "page_title", null: false
    t.bigint "pageid", null: false
    t.bigint "revision_id"
    t.string "revision_sha1"
    t.datetime "revision_timestamp"
    t.string "site", null: false
    t.string "source_attestation_id", null: false
    t.json "source_categories", default: [], null: false
    t.json "source_gaps", default: [], null: false
    t.json "source_keys", default: [], null: false
    t.datetime "updated_at", null: false
    t.text "url"
    t.index ["chengyu_form_id"], name: "index_chengyu_attestations_on_chengyu_form_id"
    t.index ["chengyu_id", "entry_language_tag"], name: "idx_chengyu_attestations_family_lang"
    t.index ["chengyu_id"], name: "index_chengyu_attestations_on_chengyu_id"
    t.index ["site", "pageid"], name: "idx_chengyu_attestations_page"
    t.index ["source_attestation_id"], name: "idx_chengyu_attestations_source_id", unique: true
  end

  create_table "chengyu_etymologies", force: :cascade do |t|
    t.integer "chengyu_form_id", null: false
    t.integer "chengyu_id", null: false
    t.datetime "created_at", null: false
    t.string "definition_language_tag"
    t.string "entry_language_tag"
    t.string "heading_path"
    t.string "page_title", null: false
    t.bigint "pageid", null: false
    t.text "plain_text"
    t.text "raw_wikitext"
    t.string "site", null: false
    t.string "source_etymology_id", null: false
    t.datetime "updated_at", null: false
    t.index ["chengyu_form_id"], name: "index_chengyu_etymologies_on_chengyu_form_id"
    t.index ["chengyu_id", "definition_language_tag"], name: "idx_chengyu_etymologies_family_lang"
    t.index ["chengyu_id"], name: "index_chengyu_etymologies_on_chengyu_id"
    t.index ["source_etymology_id"], name: "idx_chengyu_etymologies_source_id", unique: true
  end

  create_table "chengyu_form_characters", force: :cascade do |t|
    t.integer "character_codepoint_id", null: false
    t.integer "chengyu_form_id", null: false
    t.datetime "created_at", null: false
    t.string "glyph", null: false
    t.integer "position", null: false
    t.datetime "updated_at", null: false
    t.index ["character_codepoint_id", "chengyu_form_id"], name: "idx_chengyu_form_chars_lookup"
    t.index ["character_codepoint_id"], name: "index_chengyu_form_characters_on_character_codepoint_id"
    t.index ["chengyu_form_id", "position"], name: "idx_chengyu_form_chars_position", unique: true
    t.index ["chengyu_form_id"], name: "index_chengyu_form_characters_on_chengyu_form_id"
  end

  create_table "chengyu_form_relations", force: :cascade do |t|
    t.string "cause"
    t.integer "chengyu_id", null: false
    t.datetime "created_at", null: false
    t.string "merge_policy"
    t.bigint "pageid"
    t.text "raw_evidence"
    t.string "relation_type", null: false
    t.string "site"
    t.integer "source_form_id", null: false
    t.string "source_relation_id", null: false
    t.string "source_template"
    t.integer "target_form_id", null: false
    t.datetime "updated_at", null: false
    t.index ["chengyu_id"], name: "index_chengyu_form_relations_on_chengyu_id"
    t.index ["source_form_id", "target_form_id"], name: "idx_chengyu_form_relations_pair"
    t.index ["source_form_id"], name: "index_chengyu_form_relations_on_source_form_id"
    t.index ["source_relation_id"], name: "idx_chengyu_form_relations_source_id", unique: true
    t.index ["target_form_id"], name: "index_chengyu_form_relations_on_target_form_id"
  end

  create_table "chengyu_forms", force: :cascade do |t|
    t.integer "chengyu_id", null: false
    t.integer "codepoint_length", null: false
    t.boolean "contains_punctuation", default: false, null: false
    t.datetime "created_at", null: false
    t.integer "first_character_codepoint_id"
    t.string "form_text", null: false
    t.string "game_key", null: false
    t.integer "han_character_count", null: false
    t.boolean "is_display_form", default: false, null: false
    t.boolean "is_strict_han", default: false, null: false
    t.integer "last_character_codepoint_id"
    t.json "metadata", default: {}, null: false
    t.string "script_class", null: false
    t.string "source_form_id", null: false
    t.json "statuses", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["chengyu_id", "is_display_form"], name: "idx_chengyu_forms_family_display"
    t.index ["chengyu_id"], name: "index_chengyu_forms_on_chengyu_id"
    t.index ["first_character_codepoint_id", "han_character_count"], name: "idx_chengyu_forms_first_han_count"
    t.index ["first_character_codepoint_id"], name: "index_chengyu_forms_on_first_character_codepoint_id"
    t.index ["form_text"], name: "index_chengyu_forms_on_form_text"
    t.index ["game_key"], name: "index_chengyu_forms_on_game_key"
    t.index ["last_character_codepoint_id", "han_character_count"], name: "idx_chengyu_forms_last_han_count"
    t.index ["last_character_codepoint_id"], name: "index_chengyu_forms_on_last_character_codepoint_id"
    t.index ["source_form_id"], name: "index_chengyu_forms_on_source_form_id", unique: true
  end

  create_table "chengyu_imports", force: :cascade do |t|
    t.json "counts", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "fingerprint", null: false
    t.datetime "imported_at", null: false
    t.json "source_manifest", default: {}, null: false
    t.string "source_path"
    t.datetime "updated_at", null: false
    t.index ["fingerprint"], name: "index_chengyu_imports_on_fingerprint", unique: true
  end

  create_table "chengyu_provenances", force: :cascade do |t|
    t.integer "chengyu_form_id", null: false
    t.integer "chengyu_id", null: false
    t.datetime "created_at", null: false
    t.string "page_title", null: false
    t.bigint "pageid", null: false
    t.string "site", null: false
    t.string "source_category"
    t.string "source_provenance_id", null: false
    t.string "source_title"
    t.datetime "updated_at", null: false
    t.text "url"
    t.index ["chengyu_form_id"], name: "index_chengyu_provenances_on_chengyu_form_id"
    t.index ["chengyu_id", "source_category"], name: "idx_chengyu_provenances_family_category"
    t.index ["chengyu_id"], name: "index_chengyu_provenances_on_chengyu_id"
    t.index ["source_provenance_id"], name: "idx_chengyu_provenances_source_id", unique: true
  end

  create_table "chengyu_readings", force: :cascade do |t|
    t.integer "chengyu_form_id", null: false
    t.integer "chengyu_id", null: false
    t.datetime "created_at", null: false
    t.string "language_label"
    t.string "language_tag"
    t.string "page_title"
    t.bigint "pageid"
    t.text "reading", null: false
    t.string "site"
    t.string "source_reading_id", null: false
    t.string "source_template"
    t.string "source_type_code"
    t.string "system"
    t.string "system_label"
    t.datetime "updated_at", null: false
    t.text "url"
    t.index ["chengyu_form_id", "system"], name: "idx_chengyu_readings_form_system"
    t.index ["chengyu_form_id"], name: "index_chengyu_readings_on_chengyu_form_id"
    t.index ["chengyu_id", "language_tag"], name: "idx_chengyu_readings_family_lang"
    t.index ["chengyu_id"], name: "index_chengyu_readings_on_chengyu_id"
    t.index ["source_reading_id"], name: "idx_chengyu_readings_source_id", unique: true
  end

  create_table "chengyu_semantic_relations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "merge_policy"
    t.string "page_title"
    t.bigint "pageid"
    t.text "raw_definition"
    t.string "relation_language"
    t.string "relation_type", null: false
    t.string "site"
    t.integer "source_chengyu_id", null: false
    t.integer "source_form_id", null: false
    t.string "source_relation_id", null: false
    t.string "source_template"
    t.integer "target_chengyu_id"
    t.integer "target_form_id"
    t.string "target_text", null: false
    t.datetime "updated_at", null: false
    t.index ["source_chengyu_id", "relation_type"], name: "idx_chengyu_semantic_relations_source"
    t.index ["source_chengyu_id"], name: "index_chengyu_semantic_relations_on_source_chengyu_id"
    t.index ["source_form_id"], name: "index_chengyu_semantic_relations_on_source_form_id"
    t.index ["source_relation_id"], name: "idx_chengyu_semantic_relations_source_id", unique: true
    t.index ["target_chengyu_id"], name: "idx_chengyu_semantic_relations_target"
    t.index ["target_chengyu_id"], name: "index_chengyu_semantic_relations_on_target_chengyu_id"
    t.index ["target_form_id"], name: "index_chengyu_semantic_relations_on_target_form_id"
  end

  create_table "chengyu_senses", force: :cascade do |t|
    t.integer "chengyu_form_id", null: false
    t.integer "chengyu_id", null: false
    t.datetime "created_at", null: false
    t.string "definition_language_tag"
    t.string "entry_language_tag"
    t.string "heading_path"
    t.string "page_title", null: false
    t.bigint "pageid", null: false
    t.text "plain_definition", null: false
    t.text "raw_definition"
    t.string "section_kind"
    t.string "site", null: false
    t.string "source_sense_id", null: false
    t.datetime "updated_at", null: false
    t.index ["chengyu_form_id"], name: "index_chengyu_senses_on_chengyu_form_id"
    t.index ["chengyu_id", "definition_language_tag"], name: "idx_chengyu_senses_family_def_lang"
    t.index ["chengyu_id"], name: "index_chengyu_senses_on_chengyu_id"
    t.index ["source_sense_id"], name: "idx_chengyu_senses_source_id", unique: true
  end

  create_table "chengyus", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "display_form", null: false
    t.json "metadata", default: {}, null: false
    t.string "source_family_id", null: false
    t.datetime "updated_at", null: false
    t.index ["display_form"], name: "index_chengyus_on_display_form"
    t.index ["source_family_id"], name: "index_chengyus_on_source_family_id", unique: true
  end

  create_table "daily_readings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "has_text", default: true, null: false
    t.string "mother", null: false
    t.integer "order_index", null: false
    t.text "path", null: false
    t.string "series_key", null: false
    t.string "subgroup"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["series_key", "has_text", "order_index"], name: "idx_on_series_key_has_text_order_index_30cf074536"
    t.index ["series_key", "order_index"], name: "index_daily_readings_on_series_key_and_order_index", unique: true
  end

  create_table "dictionary_entries", force: :cascade do |t|
    t.boolean "contains_unresolved_glyph", default: false, null: false
    t.bigint "corpus_document_id"
    t.datetime "created_at", null: false
    t.text "definition"
    t.integer "dictionary_section_id", null: false
    t.integer "dictionary_work_id", null: false
    t.boolean "group_head", default: false, null: false
    t.integer "group_sequence"
    t.string "headword", null: false
    t.string "initial"
    t.json "metadata", default: {}, null: false
    t.string "parser_name", null: false
    t.string "parser_version", null: false
    t.text "raw_payload", null: false
    t.boolean "review_required", default: false, null: false
    t.integer "sequence_number", null: false
    t.integer "small_rime_number"
    t.integer "source_line_end"
    t.integer "source_line_start"
    t.datetime "updated_at", null: false
    t.index ["corpus_document_id", "source_line_start"], name: "idx_dictionary_entries_document_line"
    t.index ["dictionary_section_id", "group_sequence"], name: "idx_dictionary_entries_section_group"
    t.index ["dictionary_section_id"], name: "index_dictionary_entries_on_dictionary_section_id"
    t.index ["dictionary_work_id", "initial"], name: "idx_dictionary_entries_work_initial"
    t.index ["dictionary_work_id", "sequence_number"], name: "idx_dictionary_entries_work_sequence", unique: true
    t.index ["dictionary_work_id"], name: "index_dictionary_entries_on_dictionary_work_id"
    t.index ["headword"], name: "index_dictionary_entries_on_headword"
  end

  create_table "dictionary_entry_characters", force: :cascade do |t|
    t.integer "character_codepoint_id", null: false
    t.datetime "created_at", null: false
    t.integer "dictionary_entry_id", null: false
    t.string "glyph", null: false
    t.integer "position", null: false
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.index ["character_codepoint_id"], name: "index_dictionary_entry_characters_on_character_codepoint_id"
    t.index ["dictionary_entry_id", "position"], name: "idx_dictionary_entry_characters_entry_position", unique: true
    t.index ["dictionary_entry_id"], name: "index_dictionary_entry_characters_on_dictionary_entry_id"
    t.index ["glyph"], name: "index_dictionary_entry_characters_on_glyph"
  end

  create_table "dictionary_readings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "dictionary_entry_id", null: false
    t.string "kind", null: false
    t.json "metadata", default: {}, null: false
    t.integer "position", default: 1, null: false
    t.string "raw_value", null: false
    t.datetime "updated_at", null: false
    t.string "value"
    t.index ["dictionary_entry_id", "position"], name: "idx_dictionary_readings_entry_position", unique: true
    t.index ["dictionary_entry_id"], name: "index_dictionary_readings_on_dictionary_entry_id"
    t.index ["kind", "value"], name: "index_dictionary_readings_on_kind_and_value"
  end

  create_table "dictionary_references", force: :cascade do |t|
    t.bigint "corpus_document_id"
    t.bigint "corpus_work_id", null: false
    t.datetime "created_at", null: false
    t.integer "dictionary_entry_id", null: false
    t.integer "line_end"
    t.integer "line_start"
    t.json "metadata", default: {}, null: false
    t.integer "position", default: 1, null: false
    t.string "raw_sha256", null: false
    t.string "source_file", null: false
    t.string "source_kind", null: false
    t.string "source_label", null: false
    t.text "source_path", null: false
    t.string "source_record_key"
    t.datetime "updated_at", null: false
    t.index ["corpus_document_id", "line_start"], name: "idx_dictionary_references_document_line"
    t.index ["dictionary_entry_id", "position"], name: "idx_dictionary_references_entry_position", unique: true
    t.index ["dictionary_entry_id"], name: "index_dictionary_references_on_dictionary_entry_id"
    t.index ["raw_sha256"], name: "index_dictionary_references_on_raw_sha256"
    t.index ["source_kind", "source_record_key"], name: "idx_dictionary_refs_kind_record"
  end

  create_table "dictionary_sections", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "dictionary_work_id", null: false
    t.string "initial"
    t.string "label", null: false
    t.json "metadata", default: {}, null: false
    t.text "raw_heading"
    t.string "rhyme_label"
    t.integer "rhyme_number"
    t.integer "sequence_number", null: false
    t.string "tone"
    t.datetime "updated_at", null: false
    t.index ["dictionary_work_id", "sequence_number"], name: "idx_dictionary_sections_work_sequence", unique: true
    t.index ["dictionary_work_id", "tone", "rhyme_label"], name: "idx_dictionary_sections_work_tone_rhyme"
    t.index ["dictionary_work_id"], name: "index_dictionary_sections_on_dictionary_work_id"
  end

  create_table "dictionary_works", force: :cascade do |t|
    t.bigint "corpus_edition_id"
    t.bigint "corpus_work_id", null: false
    t.datetime "created_at", null: false
    t.string "edition_label"
    t.integer "entry_character_count", default: 0, null: false
    t.integer "entry_count", default: 0, null: false
    t.integer "group_count", default: 0, null: false
    t.string "import_fingerprint", null: false
    t.json "import_metadata", default: {}, null: false
    t.datetime "imported_at", null: false
    t.string "parser_name", null: false
    t.string "parser_version", null: false
    t.integer "reading_count", default: 0, null: false
    t.integer "reference_count", default: 0, null: false
    t.integer "section_count", default: 0, null: false
    t.string "source_label", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["corpus_work_id", "corpus_edition_id"], name: "idx_dictionary_works_corpus_edition", unique: true, where: "corpus_edition_id IS NOT NULL"
    t.index ["corpus_work_id"], name: "idx_dictionary_works_default_edition", unique: true, where: "corpus_edition_id IS NULL"
    t.index ["import_fingerprint"], name: "index_dictionary_works_on_import_fingerprint", unique: true
    t.index ["title"], name: "index_dictionary_works_on_title"
  end

  create_table "edit_tickets", force: :cascade do |t|
    t.datetime "closed_at"
    t.datetime "created_at", null: false
    t.json "diff_metadata", default: {}, null: false
    t.json "evidence_links", default: [], null: false
    t.string "key_digest", null: false
    t.datetime "key_generated_at", null: false
    t.string "key_salt", null: false
    t.string "public_id", null: false
    t.text "reasoning"
    t.string "source", null: false
    t.string "status", default: "open", null: false
    t.text "summary"
    t.json "tags", default: [], null: false
    t.string "target_ref", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["key_digest"], name: "index_edit_tickets_on_key_digest"
    t.index ["public_id"], name: "index_edit_tickets_on_public_id", unique: true
    t.index ["source"], name: "index_edit_tickets_on_source"
    t.index ["status"], name: "index_edit_tickets_on_status"
    t.index ["target_ref"], name: "index_edit_tickets_on_target_ref"
  end

  create_table "laoguoyin_readings", force: :cascade do |t|
    t.integer "character_codepoint_id", null: false
    t.datetime "created_at", null: false
    t.string "ipa"
    t.string "laoguoyin", null: false
    t.string "source", null: false
    t.datetime "updated_at", null: false
    t.string "zhuyin"
    t.index ["character_codepoint_id", "laoguoyin", "source"], name: "idx_laoguoyin_readings_unique", unique: true
    t.index ["character_codepoint_id"], name: "index_laoguoyin_readings_on_character_codepoint_id"
  end

  create_table "ticket_audit_events", force: :cascade do |t|
    t.string "action", null: false
    t.bigint "actor_id"
    t.string "actor_label"
    t.string "actor_type", null: false
    t.datetime "created_at", null: false
    t.integer "edit_ticket_id", null: false
    t.json "metadata", default: {}, null: false
    t.index ["action"], name: "index_ticket_audit_events_on_action"
    t.index ["created_at"], name: "index_ticket_audit_events_on_created_at"
    t.index ["edit_ticket_id"], name: "index_ticket_audit_events_on_edit_ticket_id"
  end

  create_table "ticket_contacts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "edit_ticket_id", null: false
    t.text "email"
    t.datetime "expires_at", null: false
    t.text "name"
    t.text "notes"
    t.datetime "updated_at", null: false
    t.index ["edit_ticket_id"], name: "index_ticket_contacts_on_edit_ticket_id", unique: true
    t.index ["expires_at"], name: "index_ticket_contacts_on_expires_at"
  end

  create_table "ticket_messages", force: :cascade do |t|
    t.bigint "actor_id"
    t.string "actor_label"
    t.string "actor_type", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.integer "edit_ticket_id", null: false
    t.index ["created_at"], name: "index_ticket_messages_on_created_at"
    t.index ["edit_ticket_id"], name: "index_ticket_messages_on_edit_ticket_id"
  end

  create_table "ticket_moderator_tokens", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_used_at"
    t.string "name", null: false
    t.datetime "revoked_at"
    t.string "scope", default: "review_only", null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["revoked_at"], name: "index_ticket_moderator_tokens_on_revoked_at"
    t.index ["scope"], name: "index_ticket_moderator_tokens_on_scope"
    t.index ["token_digest"], name: "index_ticket_moderator_tokens_on_token_digest", unique: true
  end

  create_table "variant_mappings", force: :cascade do |t|
    t.integer "base_codepoint"
    t.datetime "created_at", null: false
    t.string "source"
    t.datetime "updated_at", null: false
    t.integer "variant_codepoint"
    t.index ["base_codepoint"], name: "index_variant_mappings_on_base_codepoint"
    t.index ["variant_codepoint"], name: "index_variant_mappings_on_variant_codepoint", unique: true
  end

  create_table "xuanji_cells", force: :cascade do |t|
    t.string "char", null: false
    t.integer "color", default: 5, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "x", null: false
    t.integer "xuanji_grid_id", null: false
    t.integer "y", null: false
    t.index ["xuanji_grid_id", "color"], name: "index_xuanji_cells_on_xuanji_grid_id_and_color"
    t.index ["xuanji_grid_id", "x", "y"], name: "index_xuanji_cells_on_xuanji_grid_id_and_x_and_y", unique: true
    t.index ["xuanji_grid_id", "y"], name: "index_xuanji_cells_on_xuanji_grid_id_and_y"
    t.index ["xuanji_grid_id"], name: "index_xuanji_cells_on_xuanji_grid_id"
  end

  create_table "xuanji_grids", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "height", default: 29, null: false
    t.string "name", null: false
    t.text "notes"
    t.datetime "updated_at", null: false
    t.string "variant", default: "trad", null: false
    t.integer "width", default: 29, null: false
    t.index ["name", "variant"], name: "index_xuanji_grids_on_name_and_variant", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "character_input_codes", "character_codepoints"
  add_foreign_key "character_properties", "character_codepoints"
  add_foreign_key "character_structure_components", "character_structures"
  add_foreign_key "character_structures", "character_codepoints"
  add_foreign_key "chengyu_attestations", "chengyu_forms", on_delete: :cascade
  add_foreign_key "chengyu_attestations", "chengyus", on_delete: :cascade
  add_foreign_key "chengyu_etymologies", "chengyu_forms", on_delete: :cascade
  add_foreign_key "chengyu_etymologies", "chengyus", on_delete: :cascade
  add_foreign_key "chengyu_form_characters", "character_codepoints"
  add_foreign_key "chengyu_form_characters", "chengyu_forms", on_delete: :cascade
  add_foreign_key "chengyu_form_relations", "chengyu_forms", column: "source_form_id", on_delete: :cascade
  add_foreign_key "chengyu_form_relations", "chengyu_forms", column: "target_form_id", on_delete: :cascade
  add_foreign_key "chengyu_form_relations", "chengyus", on_delete: :cascade
  add_foreign_key "chengyu_forms", "character_codepoints", column: "first_character_codepoint_id"
  add_foreign_key "chengyu_forms", "character_codepoints", column: "last_character_codepoint_id"
  add_foreign_key "chengyu_forms", "chengyus", on_delete: :cascade
  add_foreign_key "chengyu_provenances", "chengyu_forms", on_delete: :cascade
  add_foreign_key "chengyu_provenances", "chengyus", on_delete: :cascade
  add_foreign_key "chengyu_readings", "chengyu_forms", on_delete: :cascade
  add_foreign_key "chengyu_readings", "chengyus", on_delete: :cascade
  add_foreign_key "chengyu_semantic_relations", "chengyu_forms", column: "source_form_id", on_delete: :cascade
  add_foreign_key "chengyu_semantic_relations", "chengyu_forms", column: "target_form_id", on_delete: :nullify
  add_foreign_key "chengyu_semantic_relations", "chengyus", column: "source_chengyu_id", on_delete: :cascade
  add_foreign_key "chengyu_semantic_relations", "chengyus", column: "target_chengyu_id", on_delete: :nullify
  add_foreign_key "chengyu_senses", "chengyu_forms", on_delete: :cascade
  add_foreign_key "chengyu_senses", "chengyus", on_delete: :cascade
  add_foreign_key "dictionary_entries", "dictionary_sections"
  add_foreign_key "dictionary_entries", "dictionary_works"
  add_foreign_key "dictionary_entry_characters", "character_codepoints"
  add_foreign_key "dictionary_entry_characters", "dictionary_entries"
  add_foreign_key "dictionary_readings", "dictionary_entries"
  add_foreign_key "dictionary_references", "dictionary_entries"
  add_foreign_key "dictionary_sections", "dictionary_works"
  add_foreign_key "laoguoyin_readings", "character_codepoints"
  add_foreign_key "ticket_audit_events", "edit_tickets"
  add_foreign_key "ticket_contacts", "edit_tickets"
  add_foreign_key "ticket_messages", "edit_tickets"
  add_foreign_key "xuanji_cells", "xuanji_grids"
end
