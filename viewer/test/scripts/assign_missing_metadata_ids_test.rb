# frozen_string_literal: true

require "csv"
require "json"
require "minitest/autorun"
require "fileutils"
require "pathname"
require "tmpdir"

require_relative "../../script/assign_missing_metadata_ids"

class AssignMissingMetadataIdsTest < Minitest::Test
  def setup
    @tmp = Pathname(Dir.mktmpdir)
    @corpus = @tmp.join("corpus")
    @registry = @tmp.join("metadata_id_registry.csv")
    @output = @tmp.join("output")
    FileUtils.mkdir_p(@corpus)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_dry_run_reuses_registry_ids_appends_new_ids_and_adds_direct_text
    make_work("日本漢文/clean/日本/室町時代/既知", {
      "schema_version" => 1,
      "title" => "既知",
      "documents" => [{ "file" => "既知.txt", "path" => "日本漢文/clean/日本/室町時代/既知/既知.txt" }]
    }, "既知.txt" => "known\n")

    make_work("日本漢文/clean/日本/室町時代/新作", {
      "schema_version" => 1,
      "work_id" => 5,
      "title" => "新作"
    }, "新作.txt" => "new\n")

    write_registry([
      registry_row("work", 1, "日本漢文/clean/日本/室町時代/既知", "既知"),
      registry_row("document", 10, "日本漢文/clean/日本/室町時代/既知/既知.txt", "既知", 1),
      registry_row("work", 4, "日本漢文/clean/日本/室町時代/旧作", "旧作", nil, "alias")
    ])

    ready = run_scan
    assert ready

    known = staged_metadata("日本漢文/clean/日本/室町時代/既知")
    assert_equal 1, known.fetch("work_id")
    assert_equal 10, known.fetch("documents").first.fetch("document_id")

    fresh = staged_metadata("日本漢文/clean/日本/室町時代/新作")
    assert_equal 5, fresh.fetch("work_id")
    assert_equal 11, fresh.fetch("documents").first.fetch("document_id")

    rows = CSV.read(@output.join("metadata_id_registry.updated.csv"), headers: true, encoding: "UTF-8").map(&:to_h)
    fresh_work = rows.find { |row| row["kind"] == "work" && row["path"].end_with?("/新作") }
    fresh_doc = rows.find { |row| row["kind"] == "document" && row["path"].end_with?("/新作.txt") }
    assert_equal "5", fresh_work.fetch("id")
    assert_equal "11", fresh_doc.fetch("id")

    # Work ID 2 is a numerical gap, but append mode does not recycle it.
    assert_equal "append", JSON.parse(@output.join("plan.json").read).fetch("allocation")
  end

  def test_apply_from_installs_exact_reviewed_files
    make_work("中國漢文/clean/明朝/大明/測試", {
      "schema_version" => 1,
      "title" => "測試",
      "documents" => [{ "file" => "測試.txt" }]
    }, "測試.txt" => "body\n")
    write_registry([])

    assert run_scan
    AssignMissingMetadataIds.apply_from(plan_root: @output)

    installed = JSON.parse(@corpus.join("中國漢文/clean/明朝/大明/測試/metadata.json").read)
    assert_equal 1, installed.fetch("work_id")
    assert_equal 1, installed.fetch("documents").first.fetch("document_id")
    assert @output.join("APPLIED.json").file?

    registry_rows = CSV.read(@registry, headers: true, encoding: "UTF-8").map(&:to_h)
    assert_equal 2, registry_rows.length
  end

  def test_duplicate_metadata_id_blocks_apply
    make_work("中國漢文/clean/唐朝/甲", {
      "schema_version" => 1,
      "work_id" => 7,
      "title" => "甲"
    }, "甲.txt" => "a\n")
    make_work("中國漢文/clean/唐朝/乙", {
      "schema_version" => 1,
      "work_id" => 7,
      "title" => "乙"
    }, "乙.txt" => "b\n")
    write_registry([])

    refute run_scan
    plan = JSON.parse(@output.join("plan.json").read)
    refute plan.fetch("ready_to_apply")
    assert_raises(RuntimeError) do
      AssignMissingMetadataIds.apply_from(plan_root: @output)
    end
  end

  def test_lowest_unused_is_explicit_and_respects_every_registry_status
    make_work("中國漢文/clean/唐朝/新", {
      "schema_version" => 1,
      "title" => "新"
    }, "新.txt" => "body\n")
    write_registry([
      registry_row("work", 1, "中國漢文/clean/唐朝/旧一", "旧一"),
      registry_row("work", 2, "中國漢文/clean/唐朝/旧二", "旧二", nil, "alias"),
      registry_row("work", 4, "中國漢文/clean/唐朝/旧四", "旧四")
    ])

    assert run_scan(allocation: "lowest-unused")
    fresh = staged_metadata("中國漢文/clean/唐朝/新")
    assert_equal 3, fresh.fetch("work_id")
  end


  def test_retired_registry_path_is_not_recycled
    path = "中國漢文/clean/唐朝/再来"
    make_work(path, {
      "schema_version" => 1,
      "title" => "再来"
    }, "再来.txt" => "body\n")
    write_registry([
      registry_row("work", 8, path, "再来", nil, "alias")
    ])

    refute run_scan
    conflicts = CSV.read(@output.join("conflicts.csv"), headers: true, encoding: "UTF-8").map(&:to_h)
    assert conflicts.any? { |row| row["code"] == "retired_registry_identity_reappeared" }
  end

  def test_apply_refuses_metadata_changed_after_review
    folder = "中國漢文/clean/宋朝/校験"
    make_work(folder, {
      "schema_version" => 1,
      "title" => "校験"
    }, "校験.txt" => "body\n")
    write_registry([])

    assert run_scan
    metadata_path = @corpus.join(folder, "metadata.json")
    metadata_path.write(JSON.pretty_generate({ "schema_version" => 1, "title" => "changed" }) + "\n", encoding: "UTF-8")

    error = assert_raises(RuntimeError) do
      AssignMissingMetadataIds.apply_from(plan_root: @output)
    end
    assert_match(/changed after dry run/, error.message)
  end

  private

  def run_scan(allocation: "append")
    AssignMissingMetadataIds.new(
      corpus_root: @corpus,
      registry_path: @registry,
      output_root: @output,
      allocation: allocation,
      include_unlisted: "direct",
      source_mode: "clean",
      progress_every: 0
    ).run
  end

  def make_work(relative_folder, metadata, files)
    folder = @corpus.join(relative_folder)
    FileUtils.mkdir_p(folder)
    folder.join("metadata.json").write(JSON.pretty_generate(metadata) + "\n", encoding: "UTF-8")
    files.each { |name, body| folder.join(name).write(body, encoding: "UTF-8") }
  end

  def staged_metadata(relative_folder)
    path = @output.join("staged_metadata", relative_folder, "metadata.json")
    JSON.parse(path.read(encoding: "UTF-8"))
  end

  def registry_row(kind, id, path, title, parent = nil, status = "active")
    {
      "kind" => kind,
      "id" => id.to_s,
      "identity_key" => "#{kind}:#{path}",
      "path" => path,
      "title" => title,
      "parent_work_id" => parent.to_s,
      "source_document_id" => "",
      "status" => status
    }
  end

  def write_registry(rows)
    CSV.open(@registry, "wb", encoding: "UTF-8") do |csv|
      csv << AssignMissingMetadataIds::REGISTRY_HEADERS
      rows.each do |row|
        csv << AssignMissingMetadataIds::REGISTRY_HEADERS.map { |header| row[header].to_s }
      end
    end
  end
end
