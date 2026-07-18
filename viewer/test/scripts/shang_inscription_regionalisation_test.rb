# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "minitest/autorun"
require "pathname"
require "tmpdir"

require_relative "../../script/shang_inscription_regionalisation"

class ShangInscriptionRegionalisationTest < Minitest::Test
  def setup
    @tmp = Pathname(Dir.mktmpdir("shang-regionalisation-test"))
    @root = @tmp.join("商殷朝")
    @plan = @tmp.join("plan")
    @registry = @tmp.join("metadata_id_registry.csv")
    @config = Pathname(__dir__).join("../../config/corpus_metadata/shang_inscription_regionalisation.yml").expand_path
    @concordances = Pathname(__dir__).join("../../config/corpus_metadata/shang_oracle_concordances.csv").expand_path
    @overrides = Pathname(__dir__).join("../../config/corpus_metadata/shang_oracle_overrides.csv").expand_path
    build_fixture
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_global_registry_allocation_h3_split_and_registry_rewrite
    run_migration

    summary = JSON.parse(@plan.join("summary.json").read)
    assert_equal 4, summary.fetch("oracle_objects")
    assert_equal 0, summary.fetch("unparsed")
    assert_equal 1003, summary.fetch("next_allocated_work_id")
    assert_equal 2003, summary.fetch("next_allocated_document_id")

    objects = CSV.read(@plan.join("object_plan.csv"), headers: true, encoding: "UTF-8").map { |row| row["title"] }
    refute_includes objects, "花東0"
    assert_includes objects, "H3：1573"
    assert_includes objects, "H3：1616"
    assert_includes objects, "H3：1630"

    registry = registry_by_kind_id(@plan.join("metadata_id_registry.updated.csv"))
    assert_equal "中國漢文/clean/商殷朝/商/甲骨文/殷墟/出土位置不詳/合集00014", registry.fetch(["work", 11]).fetch("path")
    assert_equal "merged_into_work:11", registry.fetch(["work", 13]).fetch("status")
    assert_equal "work_alias:13", registry.fetch(["work", 13]).fetch("identity_key")
    assert_equal "merged_into_work:10", registry.fetch(["work", 12]).fetch("status")
    assert_equal "中國漢文/clean/商殷朝/商/甲骨文/殷墟/花園莊東地/H3/H3：1573", registry.fetch(["work", 1001]).fetch("path")
    assert_equal "中國漢文/clean/商殷朝/商/甲骨文/殷墟/花園莊東地/H3/H3：1573/translation/eng/Schwartz/花東0.6_Schwartz.txt", registry.fetch(["document", 2001]).fetch("path")
    assert_equal "1001", registry.fetch(["document", 2001]).fetch("parent_work_id")
  end

  def test_apply_installs_reviewed_registry_and_is_second_apply_safe
    run_migration
    original_registry = Digest::SHA256.file(@registry).hexdigest

    run_migration(apply: true)

    plan = JSON.parse(@plan.join("migration_plan.json").read)
    assert_equal plan.fetch("updated_id_registry_sha256"), Digest::SHA256.file(@registry).hexdigest
    refute_equal original_registry, Digest::SHA256.file(@registry).hexdigest
    assert @plan.join("metadata_id_registry.before_shang_regionalisation.csv").file?
    assert @plan.join("APPLIED.json").file?
    assert @root.join("商/甲骨文/殷墟/花園莊東地/H3/H3：1573/metadata.json").file?

    error = assert_raises(ArgumentError) { run_migration(apply: true) }
    assert_match(/already has APPLIED/, error.message)
  end

  def test_hash_u_decoder_does_not_swallow_hexadecimal_identifier_digits
    migration = ShangInscriptionRegionalisation.new(
      shang_root: @root.to_s, output: @plan.to_s, config: @config.to_s,
      concordances: @concordances.to_s, overrides: @overrides.to_s,
      id_registry: @registry.to_s, apply: false, reviewed_plan: nil,
      scope: "oracle_bones", progress_every: 0
    )
    assert_equal "補2", migration.send(:decode_hash_u, "#U88dc2")
  end

  def test_registry_collision_outside_shang_blocks_plan
    rows = CSV.read(@registry, headers: true, encoding: "UTF-8").map(&:to_h)
    row = rows.find { |item| item["kind"] == "work" && item["id"] == "11" }
    row["path"] = "日本漢文/clean/平安時代/別作品"
    row["identity_key"] = "work:日本漢文/clean/平安時代/別作品"
    write_registry(rows)

    error = assert_raises(ArgumentError) { run_migration }
    assert_match(/belongs outside 商殷朝/, error.message)
  end

  private

  def run_migration(apply: false)
    options = {
      shang_root: @root.to_s,
      output: @plan.to_s,
      config: @config.to_s,
      concordances: @concordances.to_s,
      overrides: @overrides.to_s,
      id_registry: @registry.to_s,
      apply: apply,
      reviewed_plan: apply ? @plan.to_s : nil,
      scope: "oracle_bones",
      progress_every: 0
    }
    ShangInscriptionRegionalisation.new(options).run
  end

  def build_fixture
    write_json(@root.join("甲骨/metadata.json"), base_metadata(10, "甲骨"))

    write_oracle_segment(
      folder: "甲骨/segment_1", work_id: 11, document_id: 21,
      title: "ASDC｜甲骨｜商｜甲骨文合集｜00014正.1", file: "00014正.1.txt", text: "甲"
    )
    write_oracle_segment(
      folder: "甲骨/segment_2", work_id: 13, document_id: 22,
      title: "ASDC｜甲骨｜商｜甲骨文合集｜00014正.2", file: "00014正.2.txt", text: "乙"
    )

    legacy = @root.join("花園庄（洹北）/花园庄东地甲骨")
    write_json(legacy.join("metadata.json"), base_metadata(12, "甲骨"))
    translations = legacy.join("英譯文")
    {
      "HYZ 0.6.txt" => "H3:1573\n",
      "HYZ 0.7.txt" => "H3:1616\n",
      "HYZ 0.9.txt" => "H3:1630\n"
    }.each do |name, text|
      FileUtils.mkdir_p(translations)
      translations.join(name).write(text, encoding: "UTF-8")
    end

    write_registry([
      registry_row("work", 10, "中國漢文/clean/商殷朝/甲骨", "甲骨"),
      registry_row("work", 11, "中國漢文/clean/商殷朝/甲骨/segment_1", "segment 1"),
      registry_row("work", 12, "中國漢文/clean/商殷朝/花園庄（洹北）/花园庄东地甲骨", "甲骨"),
      registry_row("work", 13, "中國漢文/clean/商殷朝/甲骨/segment_2", "segment 2"),
      registry_row("document", 21, "中國漢文/clean/商殷朝/甲骨/segment_1/00014正.1.txt", "00014正.1", 11),
      registry_row("document", 22, "中國漢文/clean/商殷朝/甲骨/segment_2/00014正.2.txt", "00014正.2", 13),
      registry_row("work", 1000, "日本漢文/clean/平安時代/外部作品", "外部作品"),
      registry_row("document", 2000, "日本漢文/clean/平安時代/外部作品/外部作品.txt", "外部作品", 1000)
    ])
  end

  def base_metadata(work_id, title)
    {
      "schema_version" => 1,
      "work_id" => work_id,
      "corpus_root" => "中國漢文",
      "macro_region" => "中國",
      "period" => "商朝",
      "polity" => "商",
      "title" => title,
      "is_compilation" => true,
      "documents" => []
    }
  end

  def write_oracle_segment(folder:, work_id:, document_id:, title:, file:, text:)
    directory = @root.join(folder)
    FileUtils.mkdir_p(directory)
    directory.join(file).write(text, encoding: "UTF-8")
    payload = base_metadata(work_id, title).merge(
      "is_compilation" => false,
      "documents" => [{
        "document_id" => document_id,
        "file" => file,
        "path" => "中國漢文/clean/商殷朝/#{folder}/#{file}",
        "body_start_line" => 1
      }]
    )
    write_json(directory.join("metadata.json"), payload)
  end

  def write_json(path, payload)
    FileUtils.mkdir_p(path.dirname)
    path.write(JSON.pretty_generate(payload) + "\n", encoding: "UTF-8")
  end

  def registry_row(kind, id, path, title, parent_work_id = nil)
    {
      "kind" => kind,
      "id" => id.to_s,
      "identity_key" => "#{kind}:#{path}",
      "path" => path,
      "title" => title,
      "parent_work_id" => parent_work_id.to_s,
      "source_document_id" => "",
      "status" => "active"
    }
  end

  def write_registry(rows)
    headers = ShangInscriptionRegionalisation::REGISTRY_HEADERS
    CSV.open(@registry, "w", write_headers: true, headers: headers) do |csv|
      rows.each { |row| csv << headers.map { |header| row[header] } }
    end
  end

  def registry_by_kind_id(path)
    CSV.read(path, headers: true, encoding: "UTF-8").to_h do |row|
      [[row["kind"], row["id"].to_i], row.to_h]
    end
  end
end
