# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "minitest/autorun"
require "pathname"
require "tmpdir"

require_relative "../../app/services/corpus_search/document_role"
require_relative "../../app/services/corpus_metadata_id_reconciler"

class CorpusMetadataIdReconcilerTest < Minitest::Test
  def setup
    @tmp = Pathname(Dir.mktmpdir("metadata-id-reconciler-test"))
    @root = @tmp.join("corpus")
    @output = @tmp.join("output")
    @registry = @root.join(".metadata_id_registry.csv")

    write_work("甲", work_id: 10, document_id: 20)
    write_work("乙", work_id: 10, document_id: 20)
    write_work("丙", work_id: nil, document_id: nil)

    @root.join("中國漢文/clean/唐朝/丙/丙補.txt").write("補文\n", encoding: "UTF-8")
    orphan = @root.join("中國漢文/clean/唐朝/丁")
    orphan.mkpath
    orphan.join("丁.txt").write("丁文\n", encoding: "UTF-8")

    write_registry([
      registry_row("work", 10, "work:中國漢文/clean/唐朝/乙", "中國漢文/clean/唐朝/乙", "乙"),
      registry_row("document", 20, "document:中國漢文/clean/唐朝/乙/乙.txt", "中國漢文/clean/唐朝/乙/乙.txt", "乙")
    ])
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_repairs_missing_and_duplicate_ids_and_adds_unlisted_texts
    result = run_reconciler

    a = read_json("甲")
    b = read_json("乙")
    c = read_json("丙")
    d = read_json("丁")

    assert_equal 10, b.fetch("work_id")
    assert_equal 20, b.fetch("documents").first.fetch("document_id")
    refute_equal 10, a.fetch("work_id")
    refute_equal 20, a.fetch("documents").first.fetch("document_id")

    works = [a, b, c, d].map { |metadata| metadata.fetch("work_id") }
    assert_equal works.length, works.uniq.length
    assert works.all? { |id| id.is_a?(Integer) && id.positive? }

    documents = [a, b, c, d].flat_map { |metadata| metadata.fetch("documents") }
    document_ids = documents.map { |document| document.fetch("document_id") }
    assert_equal document_ids.length, document_ids.uniq.length
    assert document_ids.all? { |id| id.is_a?(Integer) && id.positive? }

    assert_equal ["丙.txt", "丙補.txt"], c.fetch("documents").map { |document| document.fetch("file") }.sort
    assert_equal ["丁.txt"], d.fetch("documents").map { |document| document.fetch("file") }
    assert result.assigned_ids.positive?
    assert_equal 2, result.reassigned_conflicts
    assert_equal 2, result.added_document_records
    assert_equal 1, result.created_metadata_files
    assert @registry.file?
  end

  def test_second_run_is_idempotent
    run_reconciler
    first = snapshot
    result = run_reconciler

    assert_equal first, snapshot
    assert_equal 0, result.assigned_ids
    assert_equal 0, result.reassigned_conflicts
    assert_equal 0, result.added_document_records
    assert_equal 0, result.created_metadata_files
    assert_equal 0, result.changed_metadata_files
  end

  private

  def run_reconciler
    CorpusMetadataIdReconciler.new(
      root: @root,
      registry_path: @registry,
      output_root: @output,
      progress_every: 0
    ).run!
  end

  def write_work(title, work_id:, document_id:)
    dir = @root.join("中國漢文/clean/唐朝", title)
    dir.mkpath
    file = "#{title}.txt"
    dir.join(file).write("#{title}文\n", encoding: "UTF-8")
    dir.join("metadata.json").write(JSON.pretty_generate({
      "schema_version" => 1,
      "work_id" => work_id,
      "title" => title,
      "documents" => [{
        "document_id" => document_id,
        "file" => file,
        "path" => "中國漢文/clean/唐朝/#{title}/#{file}"
      }]
    }) + "\n", encoding: "UTF-8")
  end

  def write_registry(rows)
    @registry.dirname.mkpath
    CSV.open(@registry, "w", write_headers: true, headers: CorpusMetadataIdReconciler::REGISTRY_HEADERS) do |csv|
      rows.each { |row| csv << CorpusMetadataIdReconciler::REGISTRY_HEADERS.map { |header| row[header] } }
    end
  end

  def registry_row(kind, id, identity_key, path, title)
    {
      "kind" => kind,
      "id" => id.to_s,
      "identity_key" => identity_key,
      "path" => path,
      "title" => title,
      "parent_work_id" => "",
      "source_document_id" => "",
      "status" => "active"
    }
  end

  def read_json(title)
    path = @root.join("中國漢文/clean/唐朝", title, "metadata.json")
    JSON.parse(path.read(encoding: "UTF-8"))
  end

  def snapshot
    Dir.glob(@root.join("**", "metadata.json").to_s).sort.to_h do |path|
      [path, File.binread(path)]
    end
  end
end
