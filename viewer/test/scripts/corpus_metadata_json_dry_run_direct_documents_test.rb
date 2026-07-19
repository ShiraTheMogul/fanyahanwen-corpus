# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../script/corpus_metadata_json_dry_run"

class CorpusMetadataJsonDryRunDirectDocumentsTest < Minitest::Test
  class Harness < CorpusMetadataJsonDryRun
    def initialize
      @key_map = { "schema_version" => 1, "defaults" => {} }
    end

    private

    def work_folds(_work)
      { scalars: {}, lists: {}, contributors: [], identifiers: [], geography: { "corpus_root" => "中國漢文", "macro_region" => "中國" } }
    end

    def compilation_rule_for(_work)
      { "title" => "測試彙編", "categories" => [] }
    end

    def compilation_worklist(_work, _folds, _rule)
      [{ "work_id" => 99, "title" => "子作品" }]
    end

    def build_document(doc, _folds)
      { "document_id" => doc.document_id, "file" => doc.file_name, "path" => doc.path }
    end
  end

  def test_compilation_keeps_direct_documents_but_not_child_folder_documents
    direct = CorpusMetadataJsonDryRun::Doc.new(
      path: "中國漢文/clean/清朝/大清/測試彙編/卷一.txt",
      parent_folder: "中國漢文/clean/清朝/大清/測試彙編",
      file_name: "卷一.txt",
      document_id: 10
    )
    child = CorpusMetadataJsonDryRun::Doc.new(
      path: "中國漢文/clean/清朝/大清/測試彙編/子作品/子作品.txt",
      parent_folder: "中國漢文/clean/清朝/大清/測試彙編",
      file_name: "子作品.txt",
      document_id: 11
    )
    work = CorpusMetadataJsonDryRun::Work.new(
      folder: "中國漢文/clean/清朝/大清/測試彙編",
      documents: [direct, child],
      work_id: 1
    )

    payload = Harness.new.send(:build_payload, work)

    assert payload["is_compilation"]
    assert_equal [10], payload.fetch("documents").map { |doc| doc.fetch("document_id") }
    assert_equal [{ "work_id" => 99, "title" => "子作品" }], payload.fetch("worklist")
  end
end
