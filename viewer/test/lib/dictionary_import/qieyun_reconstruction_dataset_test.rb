# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "tmpdir"
require Rails.root.join("lib/dictionary_import/qieyun_reconstruction_dataset").to_s
require Rails.root.join("app/services/importers/qieyun_reconstruction_importer").to_s

class QieyunReconstructionDatasetTest < ActiveSupport::TestCase
  test "parses and imports two reconstructed editions without merging their forms" do
    Dir.mktmpdir do |tmp|
      corpus_root = Pathname(tmp).join("corpus")
      build_fixture(corpus_root)

      dataset = DictionaryImport::QieyunReconstructionDataset.new(corpus_root: corpus_root).load!

      assert_equal 909_999, dataset.work_id
      assert_equal 2, dataset.editions.length
      assert_equal 4, dataset.sections.length
      assert_equal 7, dataset.entries.length
      assert_equal 4, dataset.entries.count { |entry| entry.fetch("group_head") }
      assert_equal 2, dataset.path_mismatches.length
      assert dataset.editions.all? { |edition| edition.fetch("source_path").include?("/隋朝/切韻/") }
      assert_equal ["縦", "縱"], dataset.entries.select { |entry| entry.fetch("edition_entry_sequence") == 2 }.map { |entry| entry.fetch("headword") }

      result = Importers::QieyunReconstructionImporter.import!(dataset: dataset, replace: true, verbose: false)
      assert_equal "imported", result.fetch(:status)

      work = DictionaryWork.find_by!(corpus_work_id: 909_999)
      assert_equal "切韻", work.title
      assert_equal 4, work.dictionary_sections.count
      assert_equal 7, work.dictionary_entries.count
      assert_equal 2, work.import_metadata.fetch("editions").length
      assert_equal ["平聲", "入聲"], work.dictionary_sections.order(:sequence_number).pluck(:tone).uniq
      assert_equal ["藤田拓海復元本", "李永富復元本"], work.dictionary_sections.order(:sequence_number).map { |section| section.metadata.fetch("edition_label") }.uniq
      assert_equal ["縦", "縱"], work.dictionary_entries.where(headword: ["縦", "縱"]).order(:sequence_number).pluck(:headword)
      assert_equal 4, DictionaryReading.joins(:dictionary_entry).where(dictionary_entries: { dictionary_work_id: work.id }).count
    end
  end

  private

  def build_fixture(corpus_root)
    root = corpus_root.join("中國漢文/clean/隋朝/切韻")
    fujita = root.join("reconstruction/藤田拓海/切韻（藤田拓海復元本）.txt")
    li = root.join("reconstruction/李永富/切韻（李永富復元本）.txt")
    FileUtils.mkdir_p(fujita.dirname)
    FileUtils.mkdir_p(li.dirname)

    fujita.write(<<~TEXT, encoding: "UTF-8")
      平聲

      東韻

      ○東〈德紅反.二.〉
      縦〈縦横.〉

      入聲

      屋韻

      ○屋〈烏谷反.一.〉
    TEXT

    li.write(<<~TEXT, encoding: "UTF-8")
      平聲

      東韻

      ○東〈德紅反.三.〉
      縱〈縱横.〉
      涷〈水名.〉

      入聲

      屋韻

      ○屋〈烏谷反.一.〉
    TEXT

    metadata = {
      "schema_version" => 1,
      "work_id" => 909_999,
      "corpus_root" => "中國漢文",
      "title" => "切韻",
      "sources" => [{ "revision" => "fixture123" }],
      "editions" => [
        {
          "edition_id" => 801,
          "edition_label" => "藤田拓海復元本",
          "material_type" => "reconstruction",
          "reconstruction" => true,
          "documents" => [
            {
              "document_id" => 901,
              "file" => fujita.basename.to_s,
              "path" => "中國漢文/clean/隋朝/隋/切韻/reconstruction/藤田拓海/#{fujita.basename}"
            }
          ]
        },
        {
          "edition_id" => 802,
          "edition_label" => "李永富復元本",
          "material_type" => "reconstruction",
          "reconstruction" => true,
          "documents" => [
            {
              "document_id" => 902,
              "file" => li.basename.to_s,
              "path" => "中國漢文/clean/隋朝/隋/切韻/reconstruction/李永富/#{li.basename}"
            }
          ]
        }
      ]
    }
    root.join("metadata.json").write(JSON.pretty_generate(metadata), encoding: "UTF-8")
  end
end
