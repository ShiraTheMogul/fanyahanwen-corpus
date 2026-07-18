# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"

class ShangInscriptionRegionalisationTest < Minitest::Test
  ROOT = Pathname(__dir__).join("../..").expand_path
  SCRIPT = ROOT.join("script/shang_inscription_regionalisation.rb")
  CONFIG = ROOT.join("config/corpus_metadata/shang_inscription_regionalisation.yml")

  def setup
    @tmp = Pathname(Dir.mktmpdir("shang-regionalisation-test"))
    @shang = @tmp.join("商殷朝")
    @plan = @tmp.join("plan")
    @concordances = @tmp.join("concordances.csv")
    @overrides = @tmp.join("overrides.csv")
    FileUtils.mkdir_p(@shang)
    write_csv(@concordances, %w[series object_value canonical_series canonical_object_value source note], [])
    write_csv(@overrides, %w[series object_value target_path period polity local_polity region site area locus source note], [])
    build_fixture
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_dry_run_collapses_segments_and_preserves_translation_support_and_bronze_ids
    write_csv(
      @concordances,
      %w[series object_value canonical_series canonical_object_value source note],
      [["英國所藏甲骨", "23", "甲骨文合集", "00014", "test", "same physical object"]]
    )

    run_script
    summary = read_json(@plan.join("summary.json"))
    assert_equal 2, summary.fetch("oracle_objects")
    assert_equal 1, summary.fetch("bronze_objects")
    assert_equal 9, summary.fetch("document_moves")
    assert_equal 0, summary.fetch("unparsed")

    plan = read_json(@plan.join("migration_plan.json"))
    heji = plan.fetch("entries").find { |entry| entry["title"] == "合集00014" }
    refute_nil heji
    assert_equal 10, heji.fetch("work_id")
    assert_equal [11, 12], heji.fetch("metadata").fetch("legacy_work_ids")
    assert_equal 4, heji.fetch("metadata").fetch("documents").length
    assert_equal "商/甲骨文/殷墟/出土位置不詳/合集00014", heji.fetch("target_folder")
    assert heji.fetch("metadata").fetch("identifiers").any? { |row| row["scheme"] == "英國所藏甲骨集" && row["value"] == "23" }

    huadong = plan.fetch("entries").find { |entry| entry["title"] == "花東1" }
    refute_nil huadong
    assert_equal 1, huadong.fetch("metadata").fetch("documents").length
    translation = huadong.fetch("metadata").fetch("translations").first.fetch("documents").first
    assert_equal "eng", translation.fetch("language_code")
    assert_match %r{/translation/eng/Schwartz/花東1\.1_Schwartz\.txt\z}, translation.fetch("path")
    assert_equal 7, translation.fetch("body_start_line")
    support = huadong.fetch("metadata").fetch("support_files").first
    assert_equal "transcription_review_evidence", support.fetch("kind")

    bronze = plan.fetch("entries").find { |entry| entry["kind"] == "bronze_object" }
    assert_equal "集成00793", bronze.fetch("title")
    assert_equal "商/金文/商代中期/集成00793", bronze.fetch("target_folder")
    assert_equal "集成00793_ASDC.txt", bronze.fetch("metadata").fetch("documents").first.fetch("file")

    all_sources = plan.fetch("entries").flat_map { |entry| entry.fetch("moves", []) }.map { |move| move.fetch("source") }
    all_sources.concat(plan.fetch("extra_moves", []).map { |move| move.fetch("source") })
    fixture_sources = @shang.glob("**/*").select(&:file?).reject { |path| path.basename.to_s == "metadata.json" }
      .map { |path| path.relative_path_from(@shang).to_s }
    assert_equal fixture_sources.sort, all_sources.sort
  end

  def test_reviewed_override_changes_path_and_geography_without_changing_object_identity
    write_csv(
      @overrides,
      %w[series object_value target_path period polity local_polity region site area locus source note],
      [["甲骨文合集", "00014", "周方/甲骨文/周原/鳳雛", "商朝", "商", "周方", "周原", "周原", "鳳雛", "", "test source", "reviewed test override"]]
    )

    run_script
    plan = read_json(@plan.join("migration_plan.json"))
    heji = plan.fetch("entries").find { |entry| entry["title"] == "合集00014" }
    assert_equal "周方/甲骨文/周原/鳳雛/合集00014", heji.fetch("target_folder")
    metadata = heji.fetch("metadata")
    assert_equal "周方", metadata.fetch("local_polity")
    assert_equal({ "site" => "周原", "area" => "鳳雛" }, metadata.fetch("findspot"))
    assert_includes metadata.fetch("sources"), "test source"
    assert_includes metadata.fetch("notes"), "reviewed test override"
  end

  def test_apply_is_hash_checked_resume_safe_and_removes_the_old_tree
    run_script
    run_script("--reviewed-plan", @plan.to_s, "--apply")

    assert @plan.join("APPLIED.json").file?
    refute @shang.join("甲骨").exist?
    refute @shang.join("金文").exist?
    refute @shang.join("花園庄（洹北）").exist?
    assert @shang.join("商/甲骨文/殷墟/出土位置不詳/合集00014/合集00014正.1_ASDC.txt").file?
    assert @shang.join("商/甲骨文/殷墟/花園莊東地/H3/花東1/translation/eng/Schwartz/花東1.1_Schwartz.txt").file?
    assert @shang.join("商/金文/商代中期/集成00793/集成00793_ASDC.txt").file?

    metadata = read_json(@shang.join("商/甲骨文/殷墟/出土位置不詳/合集00014/metadata.json"))
    assert_equal 10, metadata.fetch("work_id")
    assert_equal 3, metadata.fetch("documents").length

    _out, err, status = run_script("--reviewed-plan", @plan.to_s, "--apply", expect_success: false)
    refute status.success?
    assert_includes err, "APPLIED.json"
  end

  private

  def run_script(*extra, expect_success: true)
    command = [
      RbConfig.ruby,
      SCRIPT.to_s,
      "--shang-root", @shang.to_s,
      "--config", CONFIG.to_s,
      "--concordances", @concordances.to_s,
      "--overrides", @overrides.to_s,
      "--output", @plan.to_s,
      "--progress-every", "0",
      *extra
    ]
    out, err, status = Open3.capture3({ "LANG" => "C.UTF-8", "LC_ALL" => "C.UTF-8" }, *command)
    out = out.dup.force_encoding(Encoding::UTF_8).scrub
    err = err.dup.force_encoding(Encoding::UTF_8).scrub
    assert status.success?, "command failed:\n#{command.join(' ')}\nSTDOUT:\n#{out}\nSTDERR:\n#{err}" if expect_success
    [out, err, status]
  end

  def build_fixture
    write_json(@shang.join("甲骨/metadata.json"), collection_metadata(1, "甲骨"))
    write_oracle_segment("甲骨文合集", "00014正.1", 10, 100, "甲骨第一辭")
    write_oracle_segment("甲骨文合集", "00014正.2", 11, 101, "甲骨第二辭")
    write_oracle_segment("英國所藏甲骨", "23.1", 12, 102, "英藏同片辭")

    heji_root = @shang.join("花園庄（洹北）/甲骨文合集")
    write_text(heji_root.join("Heji 00014正.3.txt"), legacy_text("Heji 00014正.3", "甲骨第三辭"))
    write_json(heji_root.join("metadata.json"), compilation_metadata(2, "Heji 00014正.3.txt", 103))

    huadong_root = @shang.join("花園庄（洹北）/花园庄东地甲骨")
    write_text(huadong_root.join("HYZ 1.1.txt"), legacy_text("HYZ 1.1", "花東釋文"))
    write_json(huadong_root.join("metadata.json"), compilation_metadata(3, "HYZ 1.1.txt", 104))
    write_text(huadong_root.join("英譯文/HYZ 1.1.txt"), legacy_text("HYZ 1.1", "English translation."))
    write_text(huadong_root.join("HYZ 1.1.evidence.tsv"), "char_index\treason\n1\ttest\n")
    write_text(huadong_root.join("REVIEW_INDEX.tsv"), "file\tstatus\nHYZ 1.1\treview\n")

    write_json(@shang.join("金文/metadata.json"), collection_metadata(4, "金文"))
    bronze_folder = @shang.join("金文/中期/ASDC｜金文｜商代中期｜殷周金文集成｜00793")
    write_text(bronze_folder.join("00793_old.txt"), "亞獏\n")
    write_json(
      bronze_folder.join("metadata.json"),
      {
        "schema_version" => 1,
        "work_id" => 20,
        "corpus_root" => "中國漢文",
        "macro_region" => "中國",
        "period" => "商朝",
        "polity" => "商",
        "title" => "ASDC｜金文｜商代中期｜殷周金文集成｜00793",
        "identifiers" => [{ "scheme" => "legacy_id", "value" => "00793" }],
        "editions" => [{ "documents" => [{ "document_id" => 105, "file" => "00793_old.txt", "path" => "中國漢文/clean/商殷朝/金文/中期/x/00793_old.txt", "body_start_line" => 10 }] }]
      }
    )
  end

  def write_oracle_segment(series, locator, work_id, document_id, body)
    title = "ASDC｜甲骨｜商｜#{series}｜#{locator}"
    folder = @shang.join("甲骨/#{title}")
    file = "#{locator}_source.txt"
    write_text(folder.join(file), "#{body}\n")
    write_json(
      folder.join("metadata.json"),
      {
        "schema_version" => 1,
        "work_id" => work_id,
        "corpus_root" => "中國漢文",
        "macro_region" => "中國",
        "period" => "商朝",
        "polity" => "商",
        "title" => title,
        "identifiers" => [{ "scheme" => "legacy_id", "value" => locator }],
        "categories" => ["卜辭"],
        "sources" => ["ASDC"],
        "editions" => [{ "documents" => [{ "document_id" => document_id, "file" => file, "path" => "中國漢文/clean/商殷朝/甲骨/#{title}/#{file}", "body_start_line" => 12 }] }]
      }
    )
  end

  def collection_metadata(work_id, title)
    {
      "schema_version" => 1,
      "work_id" => work_id,
      "corpus_root" => "中國漢文",
      "macro_region" => "中國",
      "period" => "商朝",
      "polity" => "商",
      "title" => title,
      "categories" => [title],
      "is_compilation" => true
    }
  end

  def compilation_metadata(work_id, file, document_id)
    collection_metadata(work_id, "甲骨").merge(
      "identifiers" => [{ "scheme" => "catalog", "value" => File.basename(file, ".txt") }],
      "editions" => [{
        "documents" => [{
          "document_id" => document_id,
          "file" => file,
          "path" => "中國漢文/clean/商殷朝/花園庄（洹北）/#{file}",
          "sources" => ["Schwartz"],
          "identifiers" => [{ "scheme" => "catalog", "value" => File.basename(file, ".txt") }],
          "body_start_line" => 7
        }]
      }]
    )
  end

  def legacy_text(catalogue, body)
    <<~TEXT
      # WORK_BASE_TITLE: test
      # NATION: 商殷朝
      # CATEGORIES: 甲骨文
      # CATALOG: #{catalogue}
      # SOURCE: test

      #{body}
    TEXT
  end

  def write_text(path, text)
    FileUtils.mkdir_p(path.dirname)
    path.write(text, encoding: "UTF-8")
  end

  def write_json(path, payload)
    FileUtils.mkdir_p(path.dirname)
    path.write(JSON.pretty_generate(payload) + "\n", encoding: "UTF-8")
  end

  def read_json(path)
    JSON.parse(path.read(encoding: "UTF-8"))
  end

  def write_csv(path, headers, rows)
    FileUtils.mkdir_p(path.dirname)
    CSV.open(path, "w", write_headers: true, headers: headers, encoding: "UTF-8") do |csv|
      rows.each { |row| csv << row }
    end
  end
end
