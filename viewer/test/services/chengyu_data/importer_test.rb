# frozen_string_literal: true

require "test_helper"
require "csv"
require "tmpdir"

class ChengyuDataImporterTest < ActiveSupport::TestCase
  HEADERS = {
    "families.csv" => %w[family_id display_form form_count site_count language_count attestation_count definition_attestation_count reading_count sense_count etymology_count strict_han_form_count],
    "forms.csv" => %w[form_id family_id form_text is_display_form script_class codepoint_length han_character_count is_strict_han contains_punctuation statuses relation_causes evidence_types sites languages page_attestation_count definition_attestation_count relation_source_count relation_target_count],
    "attestations.csv" => %w[attestation_id family_id form_id form_text site pageid page_title entry_language_tag entry_language_source attestation_kind source_keys source_categories categories revision_id revision_timestamp revision_sha1 url has_definition_evidence source_gaps],
    "readings.csv" => %w[reading_id family_id form_id target_form reading language_tag language_label system system_label site pageid page_title source_template source_type_code url],
    "senses.csv" => %w[sense_id family_id form_id form_text site pageid page_title entry_language_tag definition_language_tag heading_path section_kind plain_definition raw_definition],
    "etymologies.csv" => %w[etymology_id family_id form_id form_text site pageid page_title entry_language_tag definition_language_tag heading_path plain_text raw_wikitext],
    "provenances.csv" => %w[provenance_id family_id form_id form_text site pageid page_title source_category source_title url],
    "form_relations.csv" => %w[relation_id family_id source_form_id source_form target_form_id target_form relation_type site pageid source_template cause raw_evidence merge_policy],
    "semantic_relations.csv" => %w[relation_id source_family_id source_form_id source_form target_family_id target_form_id target_text relation_type relation_language site pageid page_title source_template raw_definition merge_policy]
  }.freeze

  test "imports the normalized snapshot and links Han characters to the canonical registry" do
    Dir.mktmpdir("chengyu-normalized") do |dir|
      write_csv(dir, "families.csv", [["F000001", "一心一意", 1, 1, 1, 1, 1, 1, 1, 1, 1]])
      write_csv(dir, "forms.csv", [["FORM000001", "F000001", "一心一意", true, "han", 4, 4, true, false, "", "", "page_attestation", "enwiktionary", "zh", 1, 1, 0, 0]])
      write_csv(dir, "attestations.csv", [["ATT000001", "F000001", "FORM000001", "一心一意", "enwiktionary", 1, "一心一意", "zh", "heading", "category", "", "", "", 100, "2026-08-10T00:00:00Z", "abc", "https://example.test/one", true, ""]])
      write_csv(dir, "readings.csv", [["READ000001", "F000001", "FORM000001", "一心一意", "yī xīn yī yì", "cmn", "Mandarin", "pinyin", "Pinyin", "enwiktionary", 1, "一心一意", "zh-pron", "", "https://example.test/one"]])
      write_csv(dir, "senses.csv", [["SENSE000001", "F000001", "FORM000001", "一心一意", "enwiktionary", 1, "一心一意", "zh", "en", "Chinese > Idiom", "definitions", "wholeheartedly; single-mindedly", "# whole-heartedly"]])
      write_csv(dir, "etymologies.csv", [["ETY000001", "F000001", "FORM000001", "一心一意", "enwiktionary", 1, "一心一意", "zh", "en", "Chinese > Etymology", "", "{{zh-etym|一心一意}}"]])
      write_csv(dir, "provenances.csv", [])
      write_csv(dir, "form_relations.csv", [])
      write_csv(dir, "semantic_relations.csv", [])

      result = ChengyuData::Importer.new(dir: dir, batch_size: 10).import

      assert_equal 1, result.families
      assert_equal 1, result.forms
      assert_equal 4, result.form_characters
      assert_equal 1, result.attestations
      assert_equal 1, result.readings
      assert_equal 1, result.senses
      assert_equal 1, result.etymologies

      etymology = ChengyuEtymology.find_by!(source_etymology_id: "ETY000001")
      assert_nil etymology.plain_text
      assert_equal "{{zh-etym|一心一意}}", etymology.raw_wikitext

      form = ChengyuForm.find_by!(source_form_id: "FORM000001")
      assert_equal "一心一意", form.game_key
      assert_equal "一", form.first_character
      assert_equal "意", form.last_character
      assert_equal %w[一 心 一 意], form.form_characters.order(:position).pluck(:glyph)
      assert CharacterCodepoint.exists?(codepoint: "心".ord)
    end
  end

  private

  def write_csv(dir, name, rows)
    CSV.open(File.join(dir, name), "wb") do |csv|
      csv << HEADERS.fetch(name)
      rows.each { |row| csv << row }
    end
  end
end
