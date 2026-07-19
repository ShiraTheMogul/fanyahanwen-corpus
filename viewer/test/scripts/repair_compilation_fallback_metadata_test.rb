# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "csv"
require "digest"
require "pathname"

require_relative "../../script/repair_compilation_fallback_metadata"

class RepairCompilationFallbackMetadataTest < Minitest::Test

  class FailingAfterInstallRepair < CompilationFallbackRepair
    private

    def verify_final!(plan)
      super
      raise "forced post-install failure"
    end
  end
  WORKS = {
    "work_76620" => [76620, "中國漢文/clean/清朝/大清/欽定古今圖書集成", "欽定古今圖書集成"],
    "work_69565" => [69565, "中國漢文/clean/明朝/大明/永樂大典", "永樂大典"],
    "work_51009" => [51009, "中國漢文/clean/宋朝/北宋/冊府元龜", "冊府元龜"],
    "work_5445" => [5445, "中國漢文/clean/周朝/東周/戰國時代/原不詳/國語", "國語"],
    "work_75266" => [75266, "中國漢文/clean/清朝/大清/四庫全書", "四庫全書"],
    "work_8563" => [8563, "中國漢文/clean/唐朝/全唐文", "全唐文"],
    "work_74785" => [74785, "中國漢文/clean/清朝/大清/全唐文", "全唐文"],
    "work_8564" => [8564, "中國漢文/clean/唐朝/全唐詩", "全唐詩"],
    "work_74786" => [74786, "中國漢文/clean/清朝/大清/全唐詩", "全唐詩"]
  }.freeze

  def setup
    @tmp = Pathname(Dir.mktmpdir)
    @viewer = @tmp.join("viewer")
    @corpus = @tmp.join("corpus")
    @evidence = @viewer.join("config/corpus_metadata/fallback_compilation_repair")
    @output = @viewer.join("tmp/compilation_fallback_repair")
    @registry = @viewer.join("registry.csv")
    FileUtils.mkdir_p(@evidence.join("base_metadata"))
    @file_rows = []
    @registry_rows = []
    @base_specs = {}
    @next_doc = 1000
    build_fixture
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_dry_run_and_apply_repair_the_real_structural_patterns
    run_repair(apply: false)
    plan = JSON.parse(@output.join("plan.json").read(encoding: "UTF-8"))
    assert plan["ready_to_apply"], plan["blocks"].inspect
    assert_equal 13, plan.dig("summary", "source_documents")
    assert_equal 11, plan.dig("summary", "final_canonical_documents")
    assert_equal 2, plan.dig("summary", "documents_removed_as_exact_duplicates")

    run_repair(apply: true)

    ordinary = @corpus.join(WORKS.fetch("work_51009")[1], "冊府元龜__juan_01.txt")
    assert_equal "ordinary body\n", ordinary.read(encoding: "UTF-8")
    ordinary_meta = JSON.parse(ordinary.dirname.join("metadata.json").read(encoding: "UTF-8"))
    assert_equal 1, ordinary_meta.fetch("documents").length
    assert_equal 1002, ordinary_meta.fetch("documents").first.fetch("document_id")

    qtw_target = @corpus.join(WORKS.fetch("work_74785")[1])
    refute @corpus.join(WORKS.fetch("work_8563")[1]).exist?
    assert qtw_target.join("全唐文__juan_0001.txt").file?
    assert qtw_target.join("全唐文__juan_1000.txt").file?
    qtw_meta = JSON.parse(qtw_target.join("metadata.json").read(encoding: "UTF-8"))
    assert_equal 8563, qtw_meta["work_id"]
    assert_equal "清朝", qtw_meta["period"]
    assert_equal 2, qtw_meta.fetch("documents").length

    qts_target = @corpus.join(WORKS.fetch("work_74786")[1])
    refute @corpus.join(WORKS.fetch("work_8564")[1]).exist?
    assert_equal "same poem\n", qts_target.join("全唐詩__juan_0001.txt").read(encoding: "UTF-8")
    qts_meta = JSON.parse(qts_target.join("metadata.json").read(encoding: "UTF-8"))
    assert_equal [2100, 3001], qts_meta.fetch("documents").map { |doc| doc.fetch("document_id") }

    chuci_root = @corpus.join("中國漢文/clean/周朝/東周/戰國時代/楚/楚辭")
    assert chuci_root.join("九思_亂曰.txt").file?
    assert chuci_root.join("九懷_亂曰.txt").file?
    refute chuci_root.join("卷第十七/亂曰.txt").exist?
    chuci_meta = JSON.parse(chuci_root.join("metadata.json").read(encoding: "UTF-8"))
    assert_equal [4000, 4001], chuci_meta.fetch("documents").map { |doc| doc.fetch("document_id") }

    rows = CSV.read(@registry, headers: true, encoding: "bom|utf-8").map(&:to_h)
    qtw_alias = rows.find { |row| row["kind"] == "document" && row["id"] == "1999" }
    assert_equal "alias", qtw_alias["status"]
    assert_equal "2001", qtw_alias["source_document_id"]
    qts_alias = rows.find { |row| row["kind"] == "document" && row["id"] == "3000" }
    assert_equal "alias", qts_alias["status"]
    assert_equal "2100", qts_alias["source_document_id"]
  end

  def test_apply_rolls_back_after_a_forced_post_install_failure
    run_repair(apply: false)
    registry_before = @registry.binread
    ordinary = @corpus.join(WORKS.fetch("work_51009")[1], "冊府元龜__juan_01.txt")
    ordinary_before = ordinary.binread
    qtw_old = @corpus.join(WORKS.fetch("work_8563")[1], "全唐文__juan_01.txt")
    qtw_duplicate = @corpus.join(WORKS.fetch("work_74785")[1], "全唐文__juan_01.txt")

    error = assert_raises(RuntimeError) do
      run_repair(apply: true, repair_class: FailingAfterInstallRepair)
    end
    assert_match(/forced post-install failure/, error.message)

    assert qtw_old.file?, "Tang-path source should be restored"
    assert qtw_duplicate.file?, "Qing duplicate should be restored"
    assert_equal ordinary_before, ordinary.binread
    assert_equal registry_before, @registry.binread
    refute @corpus.join(WORKS.fetch("work_74785")[1], "全唐文__juan_0001.txt").exist?
  end

  def test_blocks_when_an_exact_duplicate_body_differs
    qts_complete = @corpus.join(WORKS.fetch("work_74786")[1], "全唐詩__juan_01.txt")
    qts_complete.write("# PAGE_TITLE: 全唐詩/卷001\n\nDIFFERENT\n", encoding: "UTF-8")
    update_evidence_hash!(qts_complete)
    rewrite_evidence_manifest

    run_repair(apply: false)
    plan = JSON.parse(@output.join("plan.json").read(encoding: "UTF-8"))
    refute plan["ready_to_apply"]
    assert_includes plan.fetch("blocks").map { |row| row["kind"] }, "qts_duplicate_body_mismatch"
  end

  def test_legacy_parser_keeps_body_and_metadata_separate
    result = CompilationFallbackRepair.parse_legacy("\uFEFF\n# PAGE_TITLE: 書/卷一\r\n# AUTHOR: 某人\r\n\r\n正文\r\n")
    assert_equal "正文\r\n", result.body
    assert_includes result.entries, ["PAGE_TITLE", "書/卷一"]
    assert_includes result.entries, ["AUTHOR", "某人"]
  end

  private

  def run_repair(apply:, repair_class: CompilationFallbackRepair)
    repair_class.new(
      viewer_root: @viewer,
      corpus_root: @corpus,
      evidence_root: @evidence,
      output_root: @output,
      id_registry: @registry,
      apply: apply,
      progress_every: 0
    ).run
  end

  def build_fixture
    # Ordinary direct compilation documents.
    ordinary = {
      "work_76620" => ["欽定古今圖書集成_juan_0001.txt", "# PAGE_TITLE: 欽定古今圖書集成/卷0001\n\nordinary body\n"],
      "work_69565" => ["永樂大典__juan_01.txt", "# PAGE_TITLE: 永樂大典/卷0001\n\nordinary body\n"],
      "work_51009" => ["冊府元龜__juan_01.txt", "# PAGE_TITLE: 冊府元龜/卷0001\n\nordinary body\n"],
      "work_5445" => ["國語__juan_01.txt", "# PAGE_TITLE: 國語/卷01\n\nordinary body\n"],
      "work_75266" => ["四庫全書__juan_01.txt", "# PAGE_TITLE: 四庫全書/卷1\n\nordinary body\n"]
    }
    ordinary.each_with_index do |(group, (file, text)), index|
      work_id, path, title = WORKS.fetch(group)
      create_base_metadata(group, work_id, path, title)
      create_work_registry(work_id, path, title)
      add_document(group, path, file, text, 1000 + index, work_id, volume: index + 1)
    end

    # 全唐文: lower-ID two-volume source plus one exact duplicate Qing volume.
    create_base_metadata("work_8563", 8563, WORKS.fetch("work_8563")[1], "全唐文", period: "唐朝", polity: "唐")
    create_base_metadata("work_74785", 74785, WORKS.fetch("work_74785")[1], "全唐文", period: "清朝", polity: "大清")
    create_work_registry(8563, WORKS.fetch("work_8563")[1], "全唐文")
    create_work_registry(74785, WORKS.fetch("work_74785")[1], "全唐文")
    add_document("work_8563", WORKS.fetch("work_8563")[1], "全唐文__juan_01.txt", "# PAGE_TITLE: 全唐文/卷0001\n# NATION: 唐朝\n\nvolume one\n", 2000, 8563, volume: 1)
    add_document("work_8563", WORKS.fetch("work_8563")[1], "全唐文__juan_02.txt", "# PAGE_TITLE: 全唐文/卷1000\n# NATION: 唐朝\n\nvolume thousand\n", 2001, 8563, volume: 1000)
    add_document("work_74785", WORKS.fetch("work_74785")[1], "全唐文__juan_01.txt", "# PAGE_TITLE: 全唐文/卷1000\n# NATION: 清朝\n\nvolume thousand\n", 1999, 74785, volume: 1000)

    # 全唐詩: lower-ID subset and more complete Qing witness.
    create_base_metadata("work_8564", 8564, WORKS.fetch("work_8564")[1], "全唐詩", period: "唐朝", polity: "唐")
    create_base_metadata("work_74786", 74786, WORKS.fetch("work_74786")[1], "全唐詩")
    create_work_registry(8564, WORKS.fetch("work_8564")[1], "全唐詩")
    create_work_registry(74786, WORKS.fetch("work_74786")[1], "全唐詩")
    add_document("work_8564", WORKS.fetch("work_8564")[1], "全唐詩__juan_01.txt", "# PAGE_TITLE: 全唐詩/卷001\n# NATION: 唐朝\n\nsame poem\n", 2100, 8564, volume: 1)
    add_document("work_74786", WORKS.fetch("work_74786")[1], "全唐詩__juan_01.txt", "# PAGE_TITLE: 全唐詩/卷001\n# NATION: 清朝\n\nsame poem\n", 3000, 74786, volume: 1)
    add_document("work_74786", WORKS.fetch("work_74786")[1], "全唐詩__juan_02.txt", "# PAGE_TITLE: 全唐詩/卷002\n# NATION: 清朝\n\nsecond poem\n", 3001, 74786, volume: 2)

    # 楚辭 root and two loose 亂曰 documents.
    chuci = "中國漢文/clean/周朝/東周/戰國時代/楚/楚辭"
    chuci_meta = { "schema_version" => 1, "work_id" => 5480, "title" => "楚辭", "is_compilation" => true, "worklist" => [] }
    write_json(@corpus.join(chuci, "metadata.json"), chuci_meta)
    %w[orphan_008 orphan_009].each { |group| copy_base_metadata(group, chuci_meta) }
    create_work_registry(5480, chuci, "楚辭")
    add_document("orphan_008", chuci + "/卷第十七", "亂曰.txt", "# WORK_TITLE: 楚辭\n# AUTHORS: 王逸\n\n九思末章\n", 4000, 5480, volume: nil)
    add_document("orphan_009", chuci + "/卷第十五", "亂曰.txt", "# WORK_TITLE: 楚辭\n# AUTHORS: 王褒\n\n九懷末章\n", 4001, 5480, volume: nil)

    write_registry
    write_files_csv
    write_registry_expected
    write_structure
    rewrite_evidence_manifest
  end

  def create_base_metadata(group, work_id, path, title, period: nil, polity: nil)
    data = { "schema_version" => 1, "work_id" => work_id, "corpus_root" => "中國漢文", "macro_region" => "中國", "title" => title, "is_compilation" => true, "worklist" => [] }
    data["period"] = period if period
    data["polity"] = polity if polity
    write_json(@corpus.join(path, "metadata.json"), data)
    copy_base_metadata(group, data)
  end

  def copy_base_metadata(group, data)
    path = @evidence.join("base_metadata", "#{group}.json")
    write_json(path, data)
    @base_specs[group] = { "file" => "base_metadata/#{group}.json", "sha256" => Digest::SHA256.file(path).hexdigest, "work_id" => data["work_id"], "title" => data["title"] }
  end

  def create_work_registry(id, path, title)
    @registry_rows << registry_row("work", id, path, title, "", "", "active")
  end

  def add_document(group, folder, file, text, document_id, work_id, volume:)
    path = @corpus.join(folder, file)
    FileUtils.mkdir_p(path.dirname)
    path.write(text, encoding: "UTF-8")
    rel = path.relative_path_from(@corpus).to_s
    @file_rows << {
      "group_key" => group, "source_path" => rel, "source_work_id" => work_id.to_s,
      "registry_parent_work_id" => work_id.to_s, "document_id" => document_id.to_s,
      "size_bytes" => path.size.to_s, "sha256" => Digest::SHA256.file(path).hexdigest,
      "index_page_title" => volume ? "#{WORKS[group]&.[](2) || '楚辭'}/卷#{volume.to_s.rjust(3, '0')}" : "",
      "index_work_title" => "", "index_work_base_title" => "", "index_display_title" => "",
      "index_author" => "", "index_nation" => "", "index_categories" => "", "index_chapter" => "",
      "index_source_url" => "", "index_scraped_at" => "", "volume_number" => volume.to_s,
      "proposed_role" => group.start_with?("orphan") ? "chuci_orphan" : "ordinary"
    }
    @registry_rows << registry_row("document", document_id, rel, File.basename(file, ".txt"), work_id, "", "active")
  end

  def registry_row(kind, id, path, title, parent, source, status)
    { "kind" => kind, "id" => id.to_s, "identity_key" => "#{kind}:#{path}", "path" => path, "title" => title, "parent_work_id" => parent.to_s, "source_document_id" => source.to_s, "status" => status }
  end

  def write_registry
    headers = %w[kind id identity_key path title parent_work_id source_document_id status]
    CSV.open(@registry, "wb", encoding: "UTF-8") { |csv| csv << headers; @registry_rows.each { |row| csv << headers.map { |h| row[h] } } }
  end

  def write_files_csv
    headers = @file_rows.first.keys
    CSV.open(@evidence.join("files.csv"), "wb", encoding: "UTF-8") { |csv| csv << headers; @file_rows.each { |row| csv << headers.map { |h| row[h] } } }
  end

  def write_registry_expected
    headers = %w[kind id identity_key path title parent_work_id source_document_id status]
    CSV.open(@evidence.join("registry_expected.csv"), "wb", encoding: "UTF-8") { |csv| csv << headers; @registry_rows.each { |row| csv << headers.map { |h| row[h] } } }
  end

  def write_structure
    ordinary = %w[work_76620 work_69565 work_51009 work_5445 work_75266].to_h do |group|
      id, path, = WORKS.fetch(group)
      [group, { "work_id" => id, "path" => path, "mode" => "ordinary" }]
    end
    ordinary["work_76620"].merge!("period" => "清朝", "polity" => "大清")
    ordinary["work_69565"].merge!("period" => "明朝", "polity" => "大明")
    structure = {
      "schema_version" => 1,
      "canonical_groups" => ordinary,
      "qtw" => { "title" => "全唐文", "canonical_work_id" => 8563, "alias_work_id" => 74785, "source_group" => "work_8563", "duplicate_group" => "work_74785", "source_path" => WORKS.fetch("work_8563")[1], "target_path" => WORKS.fetch("work_74785")[1], "period" => "清朝", "polity" => "大清", "filename_width" => 4, "duplicate_volume" => 1000 },
      "qts" => { "title" => "全唐詩", "canonical_work_id" => 8564, "alias_work_id" => 74786, "subset_group" => "work_8564", "complete_group" => "work_74786", "source_path" => WORKS.fetch("work_8564")[1], "target_path" => WORKS.fetch("work_74786")[1], "period" => "清朝", "polity" => "大清", "filename_width" => 4 },
      "chuci" => { "work_id" => 5480, "root_path" => "中國漢文/clean/周朝/東周/戰國時代/楚/楚辭", "moves" => [
        { "group_key" => "orphan_008", "document_id" => 4000, "target_file" => "九思_亂曰.txt", "title" => "九思·亂曰", "work_title" => "九思", "authors" => ["王逸"], "period" => "漢朝", "polity" => "漢" },
        { "group_key" => "orphan_009", "document_id" => 4001, "target_file" => "九懷_亂曰.txt", "title" => "九懷·亂曰", "work_title" => "九懷", "authors" => ["王褒"], "period" => "漢朝", "polity" => "漢" }
      ] },
      "base_metadata" => @base_specs, "expected_fallback_documents" => @file_rows.length, "expected_final_canonical_documents" => 11
    }
    write_json(@evidence.join("structure.json"), structure)
  end

  def rewrite_evidence_manifest
    files = Dir.glob(@evidence.join("**/*").to_s).map { |p| Pathname(p) }.select(&:file?).reject { |p| p.basename.to_s == "manifest.json" }.sort.map do |path|
      { "path" => path.relative_path_from(@evidence).to_s, "size_bytes" => path.size, "sha256" => Digest::SHA256.file(path).hexdigest }
    end
    write_json(@evidence.join("manifest.json"), { "version" => 1, "files" => files })
  end

  def update_evidence_hash!(path)
    rel = path.relative_path_from(@corpus).to_s
    row = @file_rows.find { |item| item["source_path"] == rel }
    row["size_bytes"] = path.size.to_s
    row["sha256"] = Digest::SHA256.file(path).hexdigest
    write_files_csv
  end

  def write_json(path, value)
    FileUtils.mkdir_p(path.dirname)
    path.write(JSON.pretty_generate(value) + "\n", encoding: "UTF-8")
  end
end
