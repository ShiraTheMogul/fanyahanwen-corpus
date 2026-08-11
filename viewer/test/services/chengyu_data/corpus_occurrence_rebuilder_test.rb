# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

class ChengyuDataCorpusOccurrenceRebuilderTest < ActiveSupport::TestCase
  test "maps an English provenance title to the canonical corpus work and ignores unrelated reuse" do
    family = Chengyu.create!(source_family_id: "CTX-F1", display_form: "一以貫之")
    form = ChengyuForm.create!(
      chengyu: family,
      source_form_id: "CTX-FORM1",
      form_text: "一以貫之",
      game_key: "一以貫之",
      is_display_form: true,
      script_class: "han",
      codepoint_length: 4,
      han_character_count: 4,
      is_strict_han: true,
      contains_punctuation: false
    )
    provenance = ChengyuProvenance.create!(
      chengyu: family,
      chengyu_form: form,
      source_provenance_id: "CTX-P1",
      site: "enwiktionary",
      pageid: 1,
      page_title: "一以貫之",
      source_category: "Category:Chinese chengyu derived from the Analects",
      source_title: "Analects"
    )

    Dir.mktmpdir("chengyu-context-test") do |root|
      analects_path = "中國漢文/clean/周朝/論語/論語__里仁第四.txt"
      later_path = "中國漢文/clean/清朝/測試/後來引用.txt"
      write_body(root, analects_path, "四之十五\n子曰：「參乎！吾道一以貫之。」")
      write_body(root, later_path, "後人亦曰一以貫之。")

      manifest = Struct.new(:documents).new([
        manifest_document(analects_path, work: "論語", title: "里仁第四", id: "13866", work_id: "5531", fingerprint: "analects"),
        manifest_document(later_path, work: "後來引用", title: "後來引用", id: "99999", work_id: "9999", fingerprint: "later")
      ])

      result = ChengyuData::CorpusOccurrenceRebuilder.new(root: root, manifest: manifest).rebuild!

      assert_equal 1, result.occurrences
      assert_equal 1, result.mapped_groups
      assert_empty result.unmapped_source_titles

      occurrence = ChengyuCorpusOccurrence.first
      assert_equal provenance.id, occurrence.chengyu_provenance_id
      assert_equal analects_path, occurrence.document_path
      assert_equal "一以貫之", occurrence.matched_text
      assert_equal "論語", occurrence.work_title
      assert_equal "里仁第四", occurrence.document_title
    end
  end

  private

  def write_body(root, relative_path, body)
    absolute = File.join(root, relative_path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.write(absolute, body, encoding: "UTF-8")
  end

  def manifest_document(path, work:, title:, id:, work_id:, fingerprint:)
    {
      "id" => id,
      "work_id" => work_id,
      "path" => path,
      "folder_path" => File.dirname(path),
      "document_role" => "canonical",
      "title" => title,
      "work" => work,
      "searchable_body" => true,
      "body_fingerprint" => fingerprint
    }
  end
end
