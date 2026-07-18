# frozen_string_literal: true

require "csv"
require "json"
require "minitest/autorun"
require "pathname"
require "tmpdir"
require_relative "../../script/shorten_audited_long_paths"

class AuditedLongPathRepairTest < Minitest::Test
  def write_registry(path, rows)
    headers = %w[kind id identity_key path title parent_work_id source_document_id status]
    CSV.open(path, "wb", row_sep: "\n") do |csv|
      csv << headers
      rows.each { |row| csv << headers.map { |header| row[header] } }
    end
  end

  def write_audit(path, rows)
    CSV.open(path, "wb", row_sep: "\n") do |csv|
      csv << %w[kind path error_class message]
      rows.each { |row| csv << ["unreadable_directory", row, "Errno::EIO", "Input/output error"] }
    end
  end

  def write_geography_map(path)
    path.write(<<~YAML, encoding: "UTF-8")
      version: 1
      rules:
        宋朝:
          macro_region: 中國
          period: 宋朝
          polity: 宋
        北宋:
          macro_region: 中國
          period: 北宋
          polity: 宋
    YAML
  end

  def build_options(root:, audit:, registry:, output:, geography:, singapore_plan:, apply: false, replan: false)
    {
      corpus_root: root.to_s,
      audit_path: audit.to_s,
      id_registry: registry.to_s,
      output_root: output.to_s,
      geography_map: geography.to_s,
      singapore_plan: singapore_plan.to_s,
      apply: apply,
      replan: replan,
      max_title_chars: 24
    }
  end

  def install_singapore_metadata(corpus)
    collection = corpus.join("新加坡漢文/clean/名勝古跡")
    child = collection.join("測試__w100")
    child.mkpath
    collection.join("metadata.json").write(JSON.pretty_generate({
      "schema_version" => 1,
      "work_id" => 100,
      "title" => "名勝古跡",
      "is_compilation" => true,
      "worklist" => []
    }) + "\n", encoding: "UTF-8")
    child.join("text.txt").write("星洲正文。\n", encoding: "UTF-8")
    child.join("metadata.json").write(JSON.pretty_generate({
      "schema_version" => 1,
      "work_id" => 101,
      "title" => "測試",
      "is_compilation" => false,
      "editions" => [
        {
          "edition_id" => 1,
          "edition_label" => "名勝古跡本",
          "documents" => [
            {
              "document_id" => 200,
              "file" => "text.txt",
              "path" => "新加坡漢文/clean/名勝古跡/測試__w100/text.txt",
              "title" => "測試"
            }
          ]
        }
      ]
    }) + "\n", encoding: "UTF-8")
  end

  def test_migrates_registry_missing_single_document_work_and_raw_mirror
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      corpus = root.join("corpus")
      output = root.join("output")
      audit = root.join("audit.csv")
      registry = root.join("metadata_id_registry.csv")
      geography = root.join("geography.yml")
      singapore_plan = root.join("singapore_plan.json")
      output.mkpath
      corpus.mkpath

      write_registry(registry, [
        {
          "kind" => "work", "id" => 10, "identity_key" => "work:既有",
          "path" => "既有", "title" => "既有", "status" => "active"
        },
        {
          "kind" => "document", "id" => 20, "identity_key" => "document:既有/text.txt",
          "path" => "既有/text.txt", "title" => "既有", "parent_work_id" => 10, "status" => "active"
        }
      ])
      write_geography_map(geography)
      singapore_plan.write(JSON.pretty_generate({
        "id_inventory" => { "last_new_work_id" => 101, "last_new_document_id" => 200 }
      }) + "\n", encoding: "UTF-8")
      install_singapore_metadata(corpus)

      title = "遊寶雲寺得唐彥猷為杭州日送客舟中手書一絕句雲山雨霏微不滿空"
      clean_rel = "中國漢文/clean/宋朝/北宋/#{title}"
      raw_rel = "中國漢文/raw/北宋/#{title}"
      clean = corpus.join(clean_rel)
      raw = corpus.join(raw_rel)
      clean.mkpath
      raw.mkpath
      clean.join("legacy.txt").write(<<~TEXT, encoding: "UTF-8")
        # TITLE: #{title}
        # AUTHOR: 蘇軾
        # SOURCE: 《東坡全集》 https://example.test/source
        # YEAR: 1100
        # EXTRA_FIELD: preserved value

        第一行。
        第二行。
      TEXT
      raw.join("raw.txt").write("# TITLE: #{title}\n\n原始文本。\n", encoding: "UTF-8")
      write_audit(audit, [clean_rel, raw_rel])

      options = build_options(
        root: corpus, audit: audit, registry: registry, output: output,
        geography: geography, singapore_plan: singapore_plan
      )
      AuditedLongPathRepair.new(options).run

      plan_bytes = output.join("long_path_plan.csv").binread
      assert plan_bytes.start_with?("\xEF\xBB\xBF".b), "review CSV must have UTF-8 BOM"
      plan = JSON.parse(output.join("plan.json").read(encoding: "UTF-8"))
      legacy = plan.fetch("rows").find { |row| row["role"] == "legacy_clean_work_migration" }
      raw_row = plan.fetch("rows").find { |row| row["role"] == "raw_mirror" }
      assert_equal 102, legacy.fetch("work_id")
      assert_equal 201, legacy.fetch("document_id")
      assert_equal false, legacy.fetch("blocked")
      assert_equal File.basename(legacy.fetch("new_path")), File.basename(raw_row.fetch("new_path"))
      assert_equal 2, plan.dig("summary", "supplemental_work_ids_reserved")
      assert_equal 1, plan.dig("summary", "supplemental_document_ids_reserved")

      AuditedLongPathRepair.new(options.merge(apply: true)).run

      new_clean = corpus.join(legacy.fetch("new_path"))
      new_raw = corpus.join(raw_row.fetch("new_path"))
      refute clean.exist?
      refute raw.exist?
      assert new_clean.directory?
      assert new_raw.directory?
      assert_equal "第一行。\n第二行。\n", new_clean.join("text.txt").read(encoding: "UTF-8")
      refute new_clean.join("legacy.txt").exist?

      metadata = JSON.parse(new_clean.join("metadata.json").read(encoding: "UTF-8"))
      assert_equal 102, metadata.fetch("work_id")
      assert_equal 201, metadata.fetch("documents").first.fetch("document_id")
      assert_equal title, metadata.fetch("title")
      assert_equal ["蘇軾"], metadata.fetch("authors")
      assert_equal "北宋", metadata.fetch("period")
      assert_equal "宋", metadata.fetch("polity")
      assert_equal ["preserved value"], metadata.dig("legacy_metadata", "EXTRA_FIELD")

      registry_rows = CSV.read(registry, headers: true, encoding: "bom|utf-8")
      work_paths = registry_rows.select { |row| row["kind"] == "work" }.map { |row| row["path"] }
      doc_paths = registry_rows.select { |row| row["kind"] == "document" }.map { |row| row["path"] }
      refute_includes work_paths, "新加坡漢文/clean/名勝古跡"
      refute_includes work_paths, "新加坡漢文/clean/名勝古跡/測試__w100"
      assert_includes work_paths, legacy.fetch("new_path")
      refute_includes doc_paths, "新加坡漢文/clean/名勝古跡/測試__w100/text.txt"
      assert_includes doc_paths, "#{legacy.fetch('new_path')}/text.txt"
      assert output.join("ROLLBACK.sh").file?
      assert output.join("migrated_legacy_works.csv").file?
    end
  end

  def test_multiple_legacy_txt_files_abort_and_restore_original_paths
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      corpus = root.join("corpus")
      output = root.join("output")
      audit = root.join("audit.csv")
      registry = root.join("metadata_id_registry.csv")
      geography = root.join("geography.yml")
      singapore_plan = root.join("missing_plan.json")
      output.mkpath
      corpus.mkpath
      write_registry(registry, [])
      write_geography_map(geography)

      title = "慶源宣義王丈以累舉得官為洪雅主簿雅州戶掾遇吏民如家人人安樂之"
      clean_rel = "中國漢文/clean/宋朝/北宋/#{title}"
      clean = corpus.join(clean_rel)
      clean.mkpath
      clean.join("one.txt").write("# TITLE: #{title}\n\n甲。\n", encoding: "UTF-8")
      clean.join("two.txt").write("# TITLE: #{title}\n\n乙。\n", encoding: "UTF-8")
      write_audit(audit, [clean_rel])

      options = build_options(
        root: corpus, audit: audit, registry: registry, output: output,
        geography: geography, singapore_plan: singapore_plan
      )
      AuditedLongPathRepair.new(options).run
      plan = JSON.parse(output.join("plan.json").read(encoding: "UTF-8"))
      planned = plan.fetch("rows").find { |row| row["role"] == "legacy_clean_work_migration" }

      error = assert_raises(ArgumentError) do
        AuditedLongPathRepair.new(options.merge(apply: true)).run
      end
      assert_match(/Expected exactly 1 TXT file/, error.message)
      assert clean.directory?, "original long path must be restored"
      refute corpus.join(planned.fetch("new_path")).exist?, "short target must be removed on rollback"
      assert_equal 2, Dir.glob(clean.join("*.txt").to_s).length
      registry_rows = CSV.read(registry, headers: true, encoding: "bom|utf-8")
      assert_empty registry_rows
    end
  end

  def test_six_missed_works_reserve_ids_after_singapore_range
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      corpus = root.join("corpus")
      output = root.join("output")
      audit = root.join("audit.csv")
      registry = root.join("metadata_id_registry.csv")
      geography = root.join("geography.yml")
      singapore_plan = root.join("singapore_plan.json")
      output.mkpath
      corpus.mkpath

      write_registry(registry, [
        {
          "kind" => "work", "id" => 128_837, "identity_key" => "work:既有",
          "path" => "既有", "title" => "既有", "status" => "active"
        },
        {
          "kind" => "document", "id" => 263_624, "identity_key" => "document:既有/text.txt",
          "path" => "既有/text.txt", "title" => "既有", "parent_work_id" => 128_837, "status" => "active"
        }
      ])
      write_geography_map(geography)
      singapore_plan.write(JSON.pretty_generate({
        "id_inventory" => { "last_new_work_id" => 129_131, "last_new_document_id" => 263_916 }
      }) + "\n", encoding: "UTF-8")

      specs = [
        ["中國漢文/clean/明朝/大明", "中國漢文/raw/明朝"],
        ["中國漢文/clean/宋朝/北宋", "中國漢文/raw/北宋"],
        ["中國漢文/clean/宋朝/北宋", "中國漢文/raw/北宋"],
        ["中國漢文/clean/宋朝/北宋", "中國漢文/raw/北宋"],
        ["中國漢文/clean/宋朝/北宋", "中國漢文/raw/北宋"],
        ["中國漢文/clean/唐朝", "中國漢文/raw/唐朝"]
      ]
      audit_paths = []
      specs.each_with_index do |(clean_parent, raw_parent), index|
        title = "第#{index + 1}件故意使用很長物理名稱但完整學術題名必須保留的作品#{'長' * 18}"
        clean_rel = "#{clean_parent}/#{title}"
        raw_rel = "#{raw_parent}/#{title}"
        clean = corpus.join(clean_rel)
        raw = corpus.join(raw_rel)
        clean.mkpath
        raw.mkpath
        clean.join("legacy.txt").write(
          "# TITLE: #{title}\n# AUTHOR: 作者#{index + 1}\n# SOURCE: 來源#{index + 1}\n\n正文#{index + 1}。\n",
          encoding: "UTF-8"
        )
        raw.join("raw.txt").write("原始#{index + 1}。\n", encoding: "UTF-8")
        audit_paths.concat([clean_rel, raw_rel])
      end
      write_audit(audit, audit_paths)

      options = build_options(
        root: corpus, audit: audit, registry: registry, output: output,
        geography: geography, singapore_plan: singapore_plan
      )
      AuditedLongPathRepair.new(options).run
      plan = JSON.parse(output.join("plan.json").read(encoding: "UTF-8"))
      legacy_rows = plan.fetch("rows").select { |row| row["role"] == "legacy_clean_work_migration" }
      raw_rows = plan.fetch("rows").select { |row| row["role"] == "raw_mirror" }

      assert_equal 6, legacy_rows.length
      assert_equal 6, raw_rows.length
      assert_equal [], plan.fetch("rows").select { |row| row["status"] == "skipped" }
      assert_equal (129_132..129_137).to_a, legacy_rows.map { |row| row.fetch("work_id") }.sort
      assert_equal (263_917..263_922).to_a, legacy_rows.map { |row| row.fetch("document_id") }.sort

      AuditedLongPathRepair.new(options.merge(apply: true)).run
      legacy_rows.each do |row|
        folder = corpus.join(row.fetch("new_path"))
        assert folder.join("metadata.json").file?
        assert folder.join("text.txt").file?
        metadata = JSON.parse(folder.join("metadata.json").read(encoding: "UTF-8"))
        assert_equal row.fetch("work_id"), metadata.fetch("work_id")
        assert_equal row.fetch("document_id"), metadata.fetch("documents").first.fetch("document_id")
        assert_equal row.fetch("title"), metadata.fetch("title")
      end
    end
  end

  def test_existing_json_work_rename_updates_metadata_and_registry_paths
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      corpus = root.join("corpus")
      output = root.join("output")
      audit = root.join("audit.csv")
      registry = root.join("metadata_id_registry.csv")
      geography = root.join("geography.yml")
      singapore_plan = root.join("missing_plan.json")
      output.mkpath
      corpus.mkpath
      write_geography_map(geography)

      title = "已有JSON但物理名稱仍然過長的作品#{'長' * 25}"
      old_rel = "中國漢文/clean/宋朝/北宋/#{title}"
      old_doc = "#{old_rel}/text.txt"
      folder = corpus.join(old_rel)
      folder.mkpath
      folder.join("text.txt").write("正文。\n", encoding: "UTF-8")
      folder.join("metadata.json").write(JSON.pretty_generate({
        "schema_version" => 1,
        "work_id" => 50,
        "title" => title,
        "is_compilation" => false,
        "documents" => [
          { "document_id" => 60, "file" => "text.txt", "path" => old_doc, "title" => title }
        ]
      }) + "\n", encoding: "UTF-8")
      write_registry(registry, [
        {
          "kind" => "work", "id" => 50, "identity_key" => "work:#{old_rel}",
          "path" => old_rel, "title" => title, "status" => "active"
        },
        {
          "kind" => "document", "id" => 60, "identity_key" => "document:#{old_doc}",
          "path" => old_doc, "title" => title, "parent_work_id" => 50, "status" => "active"
        }
      ])
      write_audit(audit, [old_rel])

      options = build_options(
        root: corpus, audit: audit, registry: registry, output: output,
        geography: geography, singapore_plan: singapore_plan
      )
      AuditedLongPathRepair.new(options).run
      plan = JSON.parse(output.join("plan.json").read(encoding: "UTF-8"))
      row = plan.fetch("rows").find { |entry| entry["role"] == "clean_work" }
      refute_nil row
      assert_nil plan.dig("summary", "first_new_work_id")

      AuditedLongPathRepair.new(options.merge(apply: true)).run
      new_folder = corpus.join(row.fetch("new_path"))
      metadata = JSON.parse(new_folder.join("metadata.json").read(encoding: "UTF-8"))
      assert_equal "#{row.fetch('new_path')}/text.txt", metadata.fetch("documents").first.fetch("path")

      registry_rows = CSV.read(registry, headers: true, encoding: "bom|utf-8")
      work = registry_rows.find { |entry| entry["kind"] == "work" }
      document = registry_rows.find { |entry| entry["kind"] == "document" }
      assert_equal row.fetch("new_path"), work["path"]
      assert_equal "work:#{row.fetch('new_path')}", work["identity_key"]
      assert_equal "#{row.fetch('new_path')}/text.txt", document["path"]
      assert_equal "document:#{row.fetch('new_path')}/text.txt", document["identity_key"]
    end
  end


  def test_copy_eio_after_quarantine_restores_the_original_long_path
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      corpus = root.join("corpus")
      output = root.join("output")
      audit = root.join("audit.csv")
      registry = root.join("metadata_id_registry.csv")
      geography = root.join("geography.yml")
      singapore_plan = root.join("missing_plan.json")
      corpus.mkpath
      output.mkpath
      write_registry(registry, [])
      write_geography_map(geography)

      title = "故意很長而且在複製階段模擬輸入輸出錯誤的作品名稱長長長長長長長長長長長長"
      clean_rel = "中國漢文/clean/宋朝/北宋/#{title}"
      clean = corpus.join(clean_rel)
      clean.mkpath
      clean.join("legacy.txt").write("# TITLE: #{title}\n\n正文。\n", encoding: "UTF-8")
      write_audit(audit, [clean_rel])

      options = build_options(
        root: corpus, audit: audit, registry: registry, output: output,
        geography: geography, singapore_plan: singapore_plan
      )
      AuditedLongPathRepair.new(options).run
      plan = JSON.parse(output.join("plan.json").read(encoding: "UTF-8"))
      planned = plan.fetch("rows").find { |row| row["status"] == "planned" }

      failing_repair = Class.new(AuditedLongPathRepair) do
        private

        def copy_directory_materialized!(_source, _destination)
          raise Errno::EIO, "simulated readdir failure"
        end
      end

      error = assert_raises(Errno::EIO) do
        failing_repair.new(options.merge(apply: true)).run
      end
      assert_match(/simulated readdir failure/, error.message)
      assert clean.directory?, "the exact original long path must be restored"
      assert clean.join("legacy.txt").file?
      refute corpus.join(planned.fetch("new_path")).exist?
      assert_empty Dir.glob(clean.dirname.join(".long_path_*__*").to_s)
      assert_empty CSV.read(registry, headers: true, encoding: "bom|utf-8")
    end
  end

  def test_wsl_windows_mount_uses_robocopy_exit_codes_zero_through_seven_as_success
    Pathname("/mnt/c").mkpath
    Dir.mktmpdir("long-path-native-", "/mnt/c") do |dir|
      root = Pathname(dir)
      corpus = root.join("corpus")
      output = root.join("output")
      audit = root.join("audit.csv")
      registry = root.join("metadata_id_registry.csv")
      geography = root.join("geography.yml")
      singapore_plan = root.join("missing_plan.json")
      fake_bin = root.join("fake-bin")
      corpus.mkpath
      output.mkpath
      fake_bin.mkpath
      write_registry(registry, [])
      write_geography_map(geography)

      fake_bin.join("wslpath").write(<<~SH, encoding: "UTF-8")
        #!/usr/bin/env bash
        printf '%s\\n' "$2"
      SH
      fake_bin.join("robocopy.exe").write(<<~SH, encoding: "UTF-8")
        #!/usr/bin/env bash
        source="$1"
        destination="$2"
        mkdir -p "$destination"
        cp -a "$source/." "$destination/"
        exit 1
      SH
      FileUtils.chmod(0o755, [fake_bin.join("wslpath"), fake_bin.join("robocopy.exe")])

      title = "故意很長並經由模擬Windows原生複製橋接處理的作品名稱長長長長長長長長長長"
      clean_rel = "中國漢文/clean/宋朝/北宋/#{title}"
      clean = corpus.join(clean_rel)
      clean.mkpath
      clean.join("legacy.txt").write("# TITLE: #{title}\n# AUTHOR: 測試者\n\n正文。\n", encoding: "UTF-8")
      write_audit(audit, [clean_rel])

      options = build_options(
        root: corpus, audit: audit, registry: registry, output: output,
        geography: geography, singapore_plan: singapore_plan
      )
      AuditedLongPathRepair.new(options).run
      plan = JSON.parse(output.join("plan.json").read(encoding: "UTF-8"))
      planned = plan.fetch("rows").find { |row| row["status"] == "planned" }

      previous_path = ENV.fetch("PATH")
      ENV["PATH"] = "#{fake_bin}:#{previous_path}"
      begin
        AuditedLongPathRepair.new(options.merge(apply: true)).run
      ensure
        ENV["PATH"] = previous_path
      end

      migrated = corpus.join(planned.fetch("new_path"))
      assert migrated.directory?
      assert_equal "正文。\n", migrated.join("text.txt").read(encoding: "UTF-8")
      metadata = JSON.parse(migrated.join("metadata.json").read(encoding: "UTF-8"))
      assert_equal planned.fetch("new_path") + "/text.txt", metadata.fetch("documents").first.fetch("path")
      summary = JSON.parse(output.join("apply_summary.json").read(encoding: "UTF-8"))
      assert_equal "robocopy", summary.fetch("directory_copy_method")
      refute clean.exist?
    end
  end

end
