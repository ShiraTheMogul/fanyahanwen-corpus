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

ActiveRecord::Schema[8.1].define(version: 2025_12_26_132100) do
  create_table "character_codepoints", force: :cascade do |t|
    t.string "chr", null: false
    t.integer "codepoint", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["chr"], name: "index_character_codepoints_on_chr"
    t.index ["codepoint"], name: "index_character_codepoints_on_codepoint", unique: true
  end

  create_table "character_properties", force: :cascade do |t|
    t.integer "character_codepoint_id", null: false
    t.datetime "created_at", null: false
    t.string "field", null: false
    t.string "source", null: false
    t.datetime "updated_at", null: false
    t.text "value", null: false
    t.index ["character_codepoint_id", "source", "field", "value"], name: "idx_character_properties_unique", unique: true
    t.index ["character_codepoint_id"], name: "index_character_properties_on_character_codepoint_id"
    t.index ["source", "field", "value"], name: "index_character_properties_on_source_field_value"
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

  create_table "variant_mappings", force: :cascade do |t|
    t.integer "base_codepoint"
    t.datetime "created_at", null: false
    t.string "source"
    t.datetime "updated_at", null: false
    t.integer "variant_codepoint"
  end

  add_foreign_key "character_properties", "character_codepoints"
  add_foreign_key "laoguoyin_readings", "character_codepoints"
end
