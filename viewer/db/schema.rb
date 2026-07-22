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

ActiveRecord::Schema[8.1].define(version: 2026_07_21_173000) do
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

  create_table "character_component_memberships", force: :cascade do |t|
    t.integer "character_codepoint_id", null: false
    t.integer "component_number", null: false
    t.datetime "created_at", null: false
    t.string "raw_token"
    t.datetime "updated_at", null: false
    t.index ["character_codepoint_id"], name: "idx_on_character_codepoint_id_50d573bd3b"
    t.index ["component_number", "character_codepoint_id"], name: "idx_ccm_component_ccid"
    t.index ["component_number"], name: "index_character_component_memberships_on_component_number"
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

  create_table "character_radical_memberships", force: :cascade do |t|
    t.integer "additional_strokes", null: false
    t.integer "character_codepoint_id", null: false
    t.datetime "created_at", null: false
    t.integer "radical_number", null: false
    t.string "raw_token"
    t.datetime "updated_at", null: false
    t.index ["character_codepoint_id"], name: "index_character_radical_memberships_on_character_codepoint_id"
    t.index ["radical_number", "additional_strokes", "character_codepoint_id"], name: "idx_crm_radical_strokes_ccid"
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
    t.index ["corpus_work_id"], name: "index_dictionary_works_on_corpus_work_id", unique: true
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

  create_table "kangxi_radicals", force: :cascade do |t|
    t.string "colloquial_names"
    t.datetime "created_at", null: false
    t.string "examples"
    t.integer "frequency"
    t.string "japanese"
    t.string "korean"
    t.string "meaning"
    t.integer "number", null: false
    t.string "pinyin"
    t.string "radical", null: false
    t.string "simplified"
    t.string "sino_vietnamese"
    t.integer "stroke_count"
    t.datetime "updated_at", null: false
    t.string "variants"
    t.index ["number"], name: "index_kangxi_radicals_on_number", unique: true
    t.index ["radical"], name: "index_kangxi_radicals_on_radical"
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

  create_table "shuowen_components", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "glyph", null: false
    t.integer "number", null: false
    t.datetime "updated_at", null: false
    t.index ["glyph"], name: "index_shuowen_components_on_glyph"
    t.index ["number"], name: "index_shuowen_components_on_number", unique: true
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
  add_foreign_key "character_component_memberships", "character_codepoints"
  add_foreign_key "character_properties", "character_codepoints"
  add_foreign_key "character_radical_memberships", "character_codepoints"
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
