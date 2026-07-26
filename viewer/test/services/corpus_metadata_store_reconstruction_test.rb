# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "tmpdir"

class CorpusMetadataStoreReconstructionTest < ActiveSupport::TestCase
  setup do
    @directory = Pathname(Dir.mktmpdir("metadata-reconstruction"))
    @work_root = @directory.join("中國漢文/clean/隋朝/隋/切韻")
    @reconstruction_path = "中國漢文/clean/隋朝/隋/切韻/reconstruction/藤田拓海/切韻（藤田拓海復元本）.txt"
    @translation_path = "中國漢文/clean/隋朝/隋/切韻/translations/eng/切韻.txt"

    write(@reconstruction_path, "○東〈德紅反.二.〉\n")
    write(@translation_path, "East.\n")

    @work_root.join("metadata.json").write(
      JSON.pretty_generate(
        "schema_version" => 1,
        "work_id" => 9001,
        "title" => "切韻",
        "editions" => [
          {
            "edition_id" => 9002,
            "edition_label" => "藤田拓海復元本",
            "material_type" => "reconstruction",
            "reconstruction" => true,
            "contributors" => [{ "name" => "藤田拓海", "role" => "reconstructor" }],
            "documents" => [
              {
                "document_id" => 9003,
                "file" => File.basename(@reconstruction_path),
                "path" => @reconstruction_path,
                "display_title" => "切韻"
              }
            ]
          }
        ],
        "translations" => [
          {
            "material_type" => "translation",
            "source_document_id" => 9003,
            "documents" => [
              {
                "document_id" => 9004,
                "file" => File.basename(@translation_path),
                "path" => @translation_path,
                "display_title" => "Qieyun"
              }
            ]
          }
        ]
      ) + "\n",
      encoding: "UTF-8"
    )

    @store = CorpusMetadataStore.new(root: @directory)
  end

  teardown do
    FileUtils.remove_entry(@directory) if @directory&.exist?
  end

  test "walks upward to the work metadata for nested document layers" do
    assert_equal @work_root.join("metadata.json"), @store.metadata_path_for(@reconstruction_path)
  end

  test "inherits reconstruction edition metadata into the document" do
    metadata = @store.document_metadata_for_path(@reconstruction_path)

    assert_equal 9001, metadata["work_id"]
    assert_equal 9002, metadata["edition_id"]
    assert_equal "藤田拓海復元本", metadata["edition_label"]
    assert_equal "reconstruction", metadata["material_type"]
    assert_equal true, metadata["reconstruction"]
    assert_equal 9003, metadata["document_id"]
  end

  test "includes reconstruction and translation documents in work navigation" do
    paths = @store.document_paths_for_work_folder("中國漢文/clean/隋朝/隋/切韻")

    assert_includes paths, @reconstruction_path
    assert_includes paths, @translation_path
  end

  test "displays reconstruction metadata fields" do
    entries = @store.display_entries_for_path(@reconstruction_path).to_h

    assert_equal "藤田拓海復元本", entries["Edition"]
    assert_equal "reconstruction", entries["Text type"]
    assert_equal "true", entries["Reconstruction"]
  end

  private

  def write(relative_path, content)
    path = @directory.join(relative_path)
    FileUtils.mkdir_p(path.dirname)
    path.write(content, encoding: "UTF-8")
  end
end
