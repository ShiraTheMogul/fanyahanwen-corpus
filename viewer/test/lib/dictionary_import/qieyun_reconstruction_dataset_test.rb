# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "json"
require "tmpdir"
require Rails.root.join("lib/dictionary_import/qieyun_reconstruction_dataset").to_s
require Rails.root.join("app/services/importers/qieyun_reconstruction_importer").to_s

class QieyunReconstructionDatasetTest < ActiveSupport::TestCase
  test "imports each reconstructed edition as its own catalogue row" do
    skip "Run bin/rails db:migrate first" unless DictionaryWork.column_names.include?("corpus_edition_id")

    Dir.mktmpdir do |tmp|
      corpus_root = Pathname(tmp).join("corpus")
      build_fixture(corpus_root)

      dataset = DictionaryImport::QieyunReconstructionDataset.new(corpus_root: corpus_root).load!

      assert_equal 909_999, dataset.work_id
      assert_equal 2, dataset.editions.length
      assert_equal 4, dataset.sections.length
      assert_equal 7, dataset.entries.length
      assert_equal 2, dataset.path_mismatches.length
      assert dataset.editions.all? { |edition| edition.fetch("input_sha256").length == 64 }

      result = Importers::QieyunReconstructionImporter.import!(dataset: dataset, replace: true, verbose: false)
      assert_equal "imported", result.fetch(:status)

      works = DictionaryWork.where(corpus_work_id: 909_999).order(:corpus_edition_id).to_a
      assert_equal 2, works.length
      assert_equal [801, 802], works.map(&:corpus_edition_id)
      assert_equal ["藤田拓海復元本", "李永富復元本"], works.map(&:edition_label)
      assert_equal [3, 4], works.map(&:entry_count)
      assert_equal [2, 2], works.map(&:section_count)

      fujita, li = works
      assert_equal ["東韻", "屋韻"], fujita.dictionary_sections.order(:sequence_number).pluck(:label)
      assert_equal ["東", "縦", "屋"], fujita.dictionary_entries.order(:sequence_number).pluck(:headword)
      assert_equal ["東", "縱", "涷", "屋"], li.dictionary_entries.order(:sequence_number).pluck(:headword)

      assert_equal [1, 2, 3], fujita.dictionary_entries.order(:sequence_number).pluck(:sequence_number)
      assert_equal [1, 2, 3, 4], li.dictionary_entries.order(:sequence_number).pluck(:sequence_number)

      second = Importers::QieyunReconstructionImporter.import!(dataset: dataset, replace: false, verbose: false)
      assert_equal "already_current", second.fetch(:status)
      assert_equal 2, DictionaryWork.where(corpus_work_id: 909_999).count
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
