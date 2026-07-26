# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require Rails.root.join("script/install_qieyun_restored_corpus").to_s

class InstallQieyunRestoredCorpusTest < ActiveSupport::TestCase
  HEADERS = %w[頁 行 音韻地位描述 聲調 韻目 序数 小韻 音類 字頭 釋義].freeze
  REGISTRY_HEADERS = %w[kind id identity_key path title parent_work_id source_document_id status].freeze

  test "allocates stable ids from the authoritative registry and builds an apply-ready corpus overlay" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      source = root.join("source")
      corpus = root.join("corpus")
      registry = root.join("metadata_id_registry.csv")
      output = root.join("output")
      source.mkpath
      corpus.mkpath
      write_sources(source)
      write_registry(registry)

      result = QieyunRestoredInstall::Installer.new(
        source_dir: source,
        corpus_root: corpus,
        id_registry_path: registry,
        output_root: output,
        source_revision: "abc123"
      ).run

      assert_equal false, result.fetch("apply")
      assert_equal 101, result.dig("ids", "work_id")
      assert_equal 201, result.dig("ids", "fujita_edition_id")
      assert_equal 202, result.dig("ids", "li_edition_id")
      assert_equal 301, result.dig("ids", "fujita_document_id")
      assert_equal 302, result.dig("ids", "li_document_id")

      metadata_path = output.join("qieyun_build/corpus_overlay/中國漢文/clean/隋朝/隋/切韻/metadata.json")
      metadata = JSON.parse(metadata_path.read(encoding: "UTF-8"))
      assert_equal 101, metadata.fetch("work_id")
      assert_equal 201, metadata.dig("editions", 0, "edition_id")
      assert_equal 302, metadata.dig("editions", 1, "documents", 0, "document_id")
      assert_equal "abc123", metadata.dig("sources", 0, "revision")

      delta = CSV.read(output.join("metadata_id_registry.qieyun_delta.csv"), headers: true)
      assert_equal 5, delta.length
      assert_equal %w[work edition edition document document].sort, delta.map { |row| row["kind"] }.sort
      refute corpus.join("中國漢文/clean/隋朝/隋/切韻").exist?
    end
  end

  test "applies the generated folder and updated registry together" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      source = root.join("source")
      corpus = root.join("corpus")
      registry = root.join("metadata_id_registry.csv")
      output = root.join("output")
      source.mkpath
      corpus.mkpath
      write_sources(source)
      write_registry(registry)

      result = QieyunRestoredInstall::Installer.new(
        source_dir: source,
        corpus_root: corpus,
        id_registry_path: registry,
        output_root: output,
        source_revision: "abc123",
        apply: true
      ).run

      assert_equal true, result.fetch("apply")
      target = corpus.join("中國漢文/clean/隋朝/隋/切韻")
      assert target.join("metadata.json").file?
      assert target.join("reconstruction/藤田拓海/切韻（藤田拓海復元本）.txt").file?
      assert target.join("reconstruction/李永富/切韻（李永富復元本）.txt").file?

      registry_rows = CSV.read(registry, headers: true)
      assert_equal 8, registry_rows.length
      assert registry_rows.any? { |row| row["identity_key"] == "work:中國漢文/clean/隋朝/隋/切韻" && row["id"] == "101" }
      assert output.join("backups/metadata_id_registry.before_qieyun.csv").file?
    end
  end

  private

  def write_sources(source)
    rows = [
      [1, 1, "端一東平", "平", "東", 1, 1, "端1", "東", "徳紅反.二."],
      [1, 2, "端一東平", "平", "東", 2, 1, "端1", "涷", "水名."]
    ]
    ["切韻 藤田拓海復元.csv", "切韻 李永富復元.csv"].each do |name|
      CSV.open(source.join(name), "w", write_headers: true, headers: HEADERS, encoding: "UTF-8") do |csv|
        rows.each { |row| csv << row }
      end
    end
  end

  def write_registry(path)
    rows = [
      ["work", 100, "work:existing", "中國漢文/clean/隋朝/隋/既有", "既有", nil, nil, "active"],
      ["edition", 200, "edition:existing", "中國漢文/clean/隋朝/隋/既有", "既有本", 100, nil, "active"],
      ["document", 300, "document:existing", "中國漢文/clean/隋朝/隋/既有/既有.txt", "既有", 100, nil, "active"]
    ]
    CSV.open(path, "w", write_headers: true, headers: REGISTRY_HEADERS, encoding: "UTF-8") do |csv|
      rows.each { |row| csv << row }
    end
  end
end
