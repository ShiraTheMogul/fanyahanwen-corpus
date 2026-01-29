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

ActiveRecord::Schema[8.1].define(version: 2026_01_28_150445) do
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

  add_foreign_key "character_component_memberships", "character_codepoints"
  add_foreign_key "character_properties", "character_codepoints"
  add_foreign_key "character_radical_memberships", "character_codepoints"
  add_foreign_key "laoguoyin_readings", "character_codepoints"
  add_foreign_key "xuanji_cells", "xuanji_grids"
end
