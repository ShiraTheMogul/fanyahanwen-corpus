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

  def write_corpus_index(path, corpus, audit_paths)
    headers = %w[kind relative_path parent_path name depth extension size_bytes is_empty_dir direct_child_dirs direct_child_files]
    CSV.open(path, "wb", row_sep: "
") do |csv|
      csv << headers
      audit_paths.each do |relative|
        folder = corpus.join(relative)
        children = Dir.children(folder).sort
        csv << [
          "dir", "corpus/#{relative}", "corpus/#{File.dirname(relative)}", File.basename(relative),
          relative.split("/").length + 1, "", "", children.empty? ? 1 : 0, 0, children.length
        ]
        children.each do |raw_name|
          name = raw_name.dup.force_encoding(Encoding::UTF_8)
          child = folder.join(name)
          next unless child.file?
          child_relative = "corpus/#{relative}/#{name}"
          csv << [
            "file", child_relative, "corpus/#{relative}", name,
            relative.split("/").length + 2, File.extname(name), child.size, 0, 0, 0
          ]
        end
      end
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

  def build_options(root:, audit:, registry:, output:, geography:, singapore_plan:, corpus_index:, apply: false, replan: false)
    {
      corpus_root: root.to_s,
      audit_path: audit.to_s,
      id_registry: registry.to_s,
      output_root: output.to_s,
      geography_map: geography.to_s,
      singapore_plan: singapore_plan.to_s,
      corpus_index: corpus_index.to_s,
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
      corpus_index = root.join("fanyahanwen-corpus_index.csv")
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
      clean_source_name = "#{title}__juan_01.txt"
      raw_source_name = "#{title}__juan_01.txt"
      clean.join(clean_source_name).write(<<~TEXT, encoding: "UTF-8")
        # TITLE: #{title}
        # AUTHOR: 蘇軾
        # SOURCE: 《東坡全集》 https://example.test/source
        # YEAR: 1100
        # NATION: 中國漢文
        # TIMES: 北宋
        # REGION: 蜀
        # AUTHOR_PAGE: https://example.test/author/su-shi
        # EXTRA_FIELD: preserved value

        第一行。
        第二行。
      TEXT
      clean.join("#{clean_source_name}.bak2").write("legacy clean backup\n", encoding: "UTF-8")
      raw.join(raw_source_name).write("# TITLE: #{title}\n\n原始文本。\n", encoding: "UTF-8")
      raw.join("#{raw_source_name}.bak2").write("legacy raw backup\n", encoding: "UTF-8")
      write_audit(audit, [clean_rel, raw_rel])
      write_corpus_index(corpus_index, corpus, [clean_rel, raw_rel])

      options = build_options(
        root: corpus, audit: audit, registry: registry, output: output,
        geography: geography, singapore_plan: singapore_plan, corpus_index: corpus_index
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
      refute new_clean.join(clean_source_name).exist?
      refute new_clean.join("#{clean_source_name}.bak2").exist?
      assert_equal "# TITLE: #{title}\n\n原始文本。\n", new_raw.join("text.txt").read(encoding: "UTF-8")
      refute new_raw.join(raw_source_name).exist?
      refute new_raw.join("#{raw_source_name}.bak2").exist?
      assert_equal ["metadata.json", "text.txt"], Dir.children(new_clean).sort
      assert_equal ["text.txt"], Dir.children(new_raw).sort

      metadata = JSON.parse(new_clean.join("metadata.json").read(encoding: "UTF-8"))
      assert_equal 102, metadata.fetch("work_id")
      assert_equal 201, metadata.fetch("documents").first.fetch("document_id")
      assert_equal title, metadata.fetch("title")
      assert_equal ["蘇軾"], metadata.fetch("authors")
      assert_equal "北宋", metadata.fetch("period")
      assert_equal "宋", metadata.fetch("polity")
      assert_equal [{ "kind" => "author_page", "value" => "https://example.test/author/su-shi" }], metadata.fetch("external_refs")
      assert_equal ["中國漢文"], metadata.dig("legacy_metadata", "NATION")
      assert_equal ["北宋"], metadata.dig("legacy_metadata", "TIMES")
      assert_equal ["蜀"], metadata.dig("legacy_metadata", "REGION")
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
      corpus_index = root.join("fanyahanwen-corpus_index.csv")
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
      write_corpus_index(corpus_index, corpus, [clean_rel])

      options = build_options(
        root: corpus, audit: audit, registry: registry, output: output,
        geography: geography, singapore_plan: singapore_plan, corpus_index: corpus_index
      )
      AuditedLongPathRepair.new(options).run
      plan = JSON.parse(output.join("plan.json").read(encoding: "UTF-8"))
      planned = plan.fetch("rows").find { |row| row["role"] == "legacy_clean_work_migration" }

      assert_equal true, planned.fetch("blocked")
      assert_equal 2, planned.fetch("indexed_txt_documents")
      error = assert_raises(ArgumentError) do
        AuditedLongPathRepair.new(options.merge(apply: true)).run
      end
      assert_match(/planned operation.*blocked/i, error.message)
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
      corpus_index = root.join("fanyahanwen-corpus_index.csv")
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
      write_corpus_index(corpus_index, corpus, audit_paths)

      options = build_options(
        root: corpus, audit: audit, registry: registry, output: output,
        geography: geography, singapore_plan: singapore_plan, corpus_index: corpus_index
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
      corpus_index = root.join("fanyahanwen-corpus_index.csv")
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
      write_corpus_index(corpus_index, corpus, [old_rel])

      options = build_options(
        root: corpus, audit: audit, registry: registry, output: output,
        geography: geography, singapore_plan: singapore_plan, corpus_index: corpus_index
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

  def test_invalid_utf8_after_child_normalisation_restores_exact_legacy_names
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      corpus = root.join("corpus")
      output = root.join("output")
      audit = root.join("audit.csv")
      registry = root.join("metadata_id_registry.csv")
      geography = root.join("geography.yml")
      singapore_plan = root.join("missing_plan.json")
      corpus_index = root.join("fanyahanwen-corpus_index.csv")
      output.mkpath
      corpus.mkpath
      write_registry(registry, [])
      write_geography_map(geography)

      title = "會在重新命名子檔案後故意因無效編碼失敗的長題名作品長長長長長長長長長長"
      clean_rel = "中國漢文/clean/宋朝/北宋/#{title}"
      clean = corpus.join(clean_rel)
      clean.mkpath
      source_name = "#{title}__juan_01.txt"
      backup_name = "#{source_name}.bak2"
      clean.join(source_name).binwrite("# TITLE: ".b + "\xFF".b + "\n\nbody\n".b)
      clean.join(backup_name).write("backup\n", encoding: "UTF-8")
      write_audit(audit, [clean_rel])
      write_corpus_index(corpus_index, corpus, [clean_rel])

      options = build_options(
        root: corpus, audit: audit, registry: registry, output: output,
        geography: geography, singapore_plan: singapore_plan, corpus_index: corpus_index
      )
      AuditedLongPathRepair.new(options).run
      plan = JSON.parse(output.join("plan.json").read(encoding: "UTF-8"))
      row = plan.fetch("rows").find { |entry| entry["role"] == "legacy_clean_work_migration" }

      assert_raises(Encoding::InvalidByteSequenceError) do
        AuditedLongPathRepair.new(options.merge(apply: true)).run
      end

      assert clean.directory?
      assert clean.join(source_name).file?, "rollback must restore the original long TXT name"
      assert clean.join(backup_name).file?, "rollback must restore the original .bak2 name"
      refute corpus.join(row.fetch("new_path")).exist?
      assert_empty CSV.read(registry, headers: true, encoding: "bom|utf-8")
    end
  end


  def test_wsl_power_shell_long_path_conversion
    repair = AuditedLongPathRepair.allocate
    converted = repair.send(:wsl_windows_path, Pathname("/mnt/c/Users/chipp/OneDrive/file.txt"))
    assert_equal '\\\\?\\C:\\Users\\chipp\\OneDrive\\file.txt', converted
  end


  def test_powershell_fallback_passes_chinese_paths_as_utf16le_base64
    Dir.mktmpdir(nil, "/mnt/c") do |dir|
      root = Pathname(dir)
      source = root.join("來源檔案.txt")
      destination = root.join("已修復.txt")
      source.write("data\n", encoding: "UTF-8")
      captured = nil
      status = Object.new
      status.define_singleton_method(:success?) { true }

      Open3.stub(:capture3, lambda { |*arguments|
        captured = arguments
        encoded = arguments.fetch(arguments.index("-EncodedCommand") + 1)
        decoded = Base64.strict_decode64(encoded).force_encoding(Encoding::UTF_16LE).encode(Encoding::UTF_8)
        assert_includes decoded, "來源檔案.txt"
        assert_includes decoded, "已修復.txt"
        refute_includes decoded, "????"
        File.rename(source, destination)
        ["", "", status]
      }) do
        repair = AuditedLongPathRepair.allocate
        repair.send(
          :powershell_move!,
          source,
          destination,
          kind: :file,
          original_error: Errno::ENAMETOOLONG.new("simulated WSL byte limit")
        )
      end

      assert_equal "-EncodedCommand", captured[-2]
      assert destination.file?
      refute source.exist?
    end
  end

  def test_failure_during_second_child_rename_restores_first_child_exactly
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      corpus = root.join("corpus")
      output = root.join("output")
      audit = root.join("audit.csv")
      registry = root.join("metadata_id_registry.csv")
      geography = root.join("geography.yml")
      singapore_plan = root.join("missing_plan.json")
      corpus_index = root.join("fanyahanwen-corpus_index.csv")
      output.mkpath
      corpus.mkpath
      write_registry(registry, [])
      write_geography_map(geography)

      title = "第二個子檔案重新命名失敗時必須完整復原第一個子檔案的長題名作品"
      clean_rel = "中國漢文/clean/宋朝/北宋/#{title}"
      clean = corpus.join(clean_rel)
      clean.mkpath
      source_name = "#{title}__juan_01.txt"
      backup_name = "#{source_name}.bak2"
      clean.join(source_name).write("# TITLE: #{title}\n\n正文。\n", encoding: "UTF-8")
      clean.join(backup_name).write("backup\n", encoding: "UTF-8")
      write_audit(audit, [clean_rel])
      write_corpus_index(corpus_index, corpus, [clean_rel])

      options = build_options(
        root: corpus, audit: audit, registry: registry, output: output,
        geography: geography, singapore_plan: singapore_plan, corpus_index: corpus_index
      )
      AuditedLongPathRepair.new(options).run
      plan = JSON.parse(output.join("plan.json").read(encoding: "UTF-8"))
      row = plan.fetch("rows").find { |entry| entry["role"] == "legacy_clean_work_migration" }

      failing_class = Class.new(AuditedLongPathRepair) do
        private

        def rename_known_path!(source, destination)
          @test_child_rename_count = @test_child_rename_count.to_i + 1
          if @test_child_rename_count == 2
            raise Errno::ENAMETOOLONG, "simulated second-child WSL failure"
          end
          super
        end
      end

      assert_raises(Errno::ENAMETOOLONG) do
        failing_class.new(options.merge(apply: true)).run
      end

      assert clean.directory?
      assert clean.join(source_name).file?, "first child must be restored after a later child fails"
      assert clean.join(backup_name).file?, "second child must remain under its exact original name"
      refute clean.join(".legacy_source.input").exist?
      refute corpus.join(row.fetch("new_path")).exist?
    end
  end

  def test_apply_recovers_a_source_left_normalized_by_an_older_failed_run
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      corpus = root.join("corpus")
      output = root.join("output")
      audit = root.join("audit.csv")
      registry = root.join("metadata_id_registry.csv")
      geography = root.join("geography.yml")
      singapore_plan = root.join("missing_plan.json")
      corpus_index = root.join("fanyahanwen-corpus_index.csv")
      output.mkpath
      corpus.mkpath
      write_registry(registry, [])
      write_geography_map(geography)

      title = "舊版失敗後來源檔已被改成暫存名稱仍應安全恢復的長題名作品"
      clean_rel = "中國漢文/clean/宋朝/北宋/#{title}"
      clean = corpus.join(clean_rel)
      clean.mkpath
      source_name = "#{title}__juan_01.txt"
      backup_name = "#{source_name}.bak2"
      clean.join(source_name).write("# TITLE: #{title}\n# AUTHOR: 蘇軾\n\n正文。\n", encoding: "UTF-8")
      clean.join(backup_name).write("backup\n", encoding: "UTF-8")
      write_audit(audit, [clean_rel])
      write_corpus_index(corpus_index, corpus, [clean_rel])

      # Reproduce the residue an older script could leave after rolling the
      # parent directory back without restoring the first child filename.
      File.rename(clean.join(source_name), clean.join(".legacy_source.input"))

      options = build_options(
        root: corpus, audit: audit, registry: registry, output: output,
        geography: geography, singapore_plan: singapore_plan, corpus_index: corpus_index
      )
      AuditedLongPathRepair.new(options).run
      plan = JSON.parse(output.join("plan.json").read(encoding: "UTF-8"))
      row = plan.fetch("rows").find { |entry| entry["role"] == "legacy_clean_work_migration" }
      AuditedLongPathRepair.new(options.merge(apply: true)).run

      migrated = corpus.join(row.fetch("new_path"))
      assert migrated.directory?
      assert_equal "正文。\n", migrated.join("text.txt").read(encoding: "UTF-8")
      metadata = JSON.parse(migrated.join("metadata.json").read(encoding: "UTF-8"))
      assert_equal title, metadata.fetch("title")
      assert_equal ["蘇軾"], metadata.fetch("authors")
    end
  end

  def test_apply_recovers_parent_directory_left_at_target_path_by_failed_run
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      corpus = root.join("corpus")
      output = root.join("output")
      audit = root.join("audit.csv")
      registry = root.join("metadata_id_registry.csv")
      geography = root.join("geography.yml")
      singapore_plan = root.join("missing_plan.json")
      corpus_index = root.join("fanyahanwen-corpus_index.csv")
      output.mkpath
      corpus.mkpath
      write_registry(registry, [])
      write_geography_map(geography)

      title = "父資料夾已留在短目標路徑且來源檔使用暫存名時仍必須自動恢復並完成遷移"
      clean_rel = "中國漢文/clean/宋朝/北宋/#{title}"
      clean = corpus.join(clean_rel)
      clean.mkpath
      source_name = "#{title}__juan_01.txt"
      backup_name = "#{source_name}.bak2"
      clean.join(source_name).write("# TITLE: #{title}\n# AUTHOR: 蘇軾\n\n正文。\n", encoding: "UTF-8")
      clean.join(backup_name).write("backup\n", encoding: "UTF-8")
      write_audit(audit, [clean_rel])
      write_corpus_index(corpus_index, corpus, [clean_rel])

      options = build_options(
        root: corpus, audit: audit, registry: registry, output: output,
        geography: geography, singapore_plan: singapore_plan, corpus_index: corpus_index
      )
      AuditedLongPathRepair.new(options).run
      plan = JSON.parse(output.join("plan.json").read(encoding: "UTF-8"))
      row = plan.fetch("rows").find { |entry| entry["role"] == "legacy_clean_work_migration" }
      target = corpus.join(row.fetch("new_path"))

      # Reproduce the real failed state: the parent was renamed, one child was
      # already shortened, and the reviewed plan still points at the old path.
      File.rename(clean, target)
      File.rename(target.join(source_name), target.join(".legacy_source.input"))
      refute clean.exist?
      assert target.directory?

      AuditedLongPathRepair.new(options.merge(apply: true)).run

      assert target.directory?
      assert_equal "正文。\n", target.join("text.txt").read(encoding: "UTF-8")
      metadata = JSON.parse(target.join("metadata.json").read(encoding: "UTF-8"))
      assert_equal title, metadata.fetch("title")
      assert_equal ["蘇軾"], metadata.fetch("authors")
      refute clean.exist?
    end
  end



  def test_apply_allows_indexed_auxiliary_backup_to_be_absent_when_canonical_txt_is_verified
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      corpus = root.join("corpus")
      output = root.join("output")
      audit = root.join("audit.csv")
      registry = root.join("metadata_id_registry.csv")
      geography = root.join("geography.yml")
      singapore_plan = root.join("missing_plan.json")
      corpus_index = root.join("fanyahanwen-corpus_index.csv")
      output.mkpath
      corpus.mkpath
      write_registry(registry, [])
      write_geography_map(geography)

      title = "索引仍列出備份但實際只剩可驗證正文的長題名作品"
      clean_rel = "中國漢文/clean/宋朝/北宋/#{title}"
      clean = corpus.join(clean_rel)
      clean.mkpath
      source_name = "#{title}__juan_01.txt"
      backup_name = "#{source_name}.bak2"
      clean.join(source_name).write("# TITLE: #{title}\n# AUTHOR: 蘇軾\n\n正文。\n", encoding: "UTF-8")
      clean.join(backup_name).write("auxiliary backup\n", encoding: "UTF-8")
      write_audit(audit, [clean_rel])
      write_corpus_index(corpus_index, corpus, [clean_rel])

      options = build_options(
        root: corpus, audit: audit, registry: registry, output: output,
        geography: geography, singapore_plan: singapore_plan, corpus_index: corpus_index
      )
      AuditedLongPathRepair.new(options).run
      plan = JSON.parse(output.join("plan.json").read(encoding: "UTF-8"))
      row = plan.fetch("rows").find { |entry| entry["role"] == "legacy_clean_work_migration" }

      # Reproduce the real state discovered after planning: the canonical TXT
      # still exists with its indexed size, while only the auxiliary .bak2 is
      # absent.
      File.delete(clean.join(backup_name))

      AuditedLongPathRepair.new(options.merge(apply: true)).run

      migrated = corpus.join(row.fetch("new_path"))
      assert migrated.directory?
      assert_equal "正文。\n", migrated.join("text.txt").read(encoding: "UTF-8")
      metadata = JSON.parse(migrated.join("metadata.json").read(encoding: "UTF-8"))
      assert_equal title, metadata.fetch("title")
      assert_equal ["蘇軾"], metadata.fetch("authors")

      apply_summary = JSON.parse(output.join("apply_summary.json").read(encoding: "UTF-8"))
      assert_equal 1, apply_summary.fetch("missing_indexed_auxiliary_files")

      report = CSV.read(output.join("migrated_legacy_works.csv"), headers: true, encoding: "bom|utf-8").first
      missing = JSON.parse(report.fetch("missing_indexed_auxiliary_files"))
      assert_includes missing, backup_name
    end
  end

  def test_apply_still_blocks_when_required_indexed_txt_is_absent
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      corpus = root.join("corpus")
      output = root.join("output")
      audit = root.join("audit.csv")
      registry = root.join("metadata_id_registry.csv")
      geography = root.join("geography.yml")
      singapore_plan = root.join("missing_plan.json")
      corpus_index = root.join("fanyahanwen-corpus_index.csv")
      output.mkpath
      corpus.mkpath
      write_registry(registry, [])
      write_geography_map(geography)

      title = "索引正文若真正缺失就必須阻止遷移的長題名作品"
      clean_rel = "中國漢文/clean/宋朝/北宋/#{title}"
      clean = corpus.join(clean_rel)
      clean.mkpath
      source_name = "#{title}__juan_01.txt"
      backup_name = "#{source_name}.bak2"
      clean.join(source_name).write("# TITLE: #{title}\n\n正文。\n", encoding: "UTF-8")
      clean.join(backup_name).write("auxiliary backup\n", encoding: "UTF-8")
      write_audit(audit, [clean_rel])
      write_corpus_index(corpus_index, corpus, [clean_rel])

      options = build_options(
        root: corpus, audit: audit, registry: registry, output: output,
        geography: geography, singapore_plan: singapore_plan, corpus_index: corpus_index
      )
      AuditedLongPathRepair.new(options).run
      plan = JSON.parse(output.join("plan.json").read(encoding: "UTF-8"))
      row = plan.fetch("rows").find { |entry| entry["role"] == "legacy_clean_work_migration" }
      File.delete(clean.join(source_name))

      error = assert_raises(IOError) do
        AuditedLongPathRepair.new(options.merge(apply: true)).run
      end
      assert_includes error.message, "Required indexed TXT child is missing"
      assert clean.directory?
      assert clean.join(backup_name).file?
      refute corpus.join(row.fetch("new_path")).exist?
    end
  end


  def test_apply_preserves_wrong_sized_preexisting_short_source_and_uses_indexed_canonical_txt
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      corpus = root.join("corpus")
      output = root.join("output")
      audit = root.join("audit.csv")
      registry = root.join("metadata_id_registry.csv")
      geography = root.join("geography.yml")
      singapore_plan = root.join("missing_plan.json")
      corpus_index = root.join("fanyahanwen-corpus_index.csv")
      output.mkpath
      corpus.mkpath
      write_registry(registry, [])
      write_geography_map(geography)

      title = "舊暫存來源名稱已有錯誤大小檔案時仍須保留衝突並使用索引正文的長題名作品"
      clean_rel = "中國漢文/clean/宋朝/北宋/#{title}"
      clean = corpus.join(clean_rel)
      clean.mkpath
      source_name = "#{title}__juan_01.txt"
      backup_name = "#{source_name}.bak2"
      prefix = "# TITLE: #{title}\n# AUTHOR: 蘇軾\n\n"
      body_prefix = "正文。"
      body = body_prefix + ("x" * (599 - prefix.bytesize - body_prefix.bytesize - 1)) + "\n"
      source_text = prefix + body
      assert_equal 599, source_text.bytesize
      stale_bytes = "x" * 1_653
      clean.join(source_name).write(source_text, encoding: "UTF-8")
      clean.join(backup_name).write("backup\n", encoding: "UTF-8")
      write_audit(audit, [clean_rel])
      write_corpus_index(corpus_index, corpus, [clean_rel])

      options = build_options(
        root: corpus, audit: audit, registry: registry, output: output,
        geography: geography, singapore_plan: singapore_plan, corpus_index: corpus_index
      )
      AuditedLongPathRepair.new(options).run
      plan = JSON.parse(output.join("plan.json").read(encoding: "UTF-8"))
      row = plan.fetch("rows").find { |entry| entry["role"] == "legacy_clean_work_migration" }

      # Reproduce the exact real-world residue: the canonical long TXT still
      # exists, but an unrelated wrong-sized file already occupies the short
      # temporary source name.
      clean.join(".legacy_source.input").binwrite(stale_bytes)

      AuditedLongPathRepair.new(options.merge(apply: true)).run

      migrated = corpus.join(row.fetch("new_path"))
      assert migrated.directory?
      assert_equal body, migrated.join("text.txt").read(encoding: "UTF-8")
      refute migrated.join(".legacy_source.input").exist?
      refute migrated.join(".repair_conflict_001.input").exist?

      summary = JSON.parse(output.join("apply_summary.json").read(encoding: "UTF-8"))
      assert_equal 1, summary.fetch("preexisting_short_name_conflicts")
      backup = Pathname(summary.fetch("backup_root")).join("clean", row.fetch("work_id").to_s)
      assert_equal stale_bytes, backup.join(".repair_conflict_001.input").binread

      report = CSV.read(output.join("migrated_legacy_works.csv"), headers: true, encoding: "bom|utf-8").first
      conflicts = JSON.parse(report.fetch("preexisting_short_name_conflicts"))
      assert_equal 1, conflicts.length
      assert_equal ".legacy_source.input", conflicts.first.fetch("normalized_name")
      assert_equal 1_653, conflicts.first.fetch("size_bytes")
    end
  end

  def test_rollback_restores_wrong_sized_preexisting_short_source_after_later_failure
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      corpus = root.join("corpus")
      output = root.join("output")
      audit = root.join("audit.csv")
      registry = root.join("metadata_id_registry.csv")
      geography = root.join("geography.yml")
      singapore_plan = root.join("missing_plan.json")
      corpus_index = root.join("fanyahanwen-corpus_index.csv")
      output.mkpath
      corpus.mkpath
      write_registry(registry, [])
      write_geography_map(geography)

      title = "衝突暫存檔隔離後若後續失敗必須原樣復原所有名稱與內容的長題名作品"
      clean_rel = "中國漢文/clean/宋朝/北宋/#{title}"
      clean = corpus.join(clean_rel)
      clean.mkpath
      source_name = "#{title}__juan_01.txt"
      backup_name = "#{source_name}.bak2"
      source_text = "# TITLE: #{title}\n\n正文。\n"
      stale_bytes = "stale" * 331
      clean.join(source_name).write(source_text, encoding: "UTF-8")
      clean.join(backup_name).write("backup\n", encoding: "UTF-8")
      write_audit(audit, [clean_rel])
      write_corpus_index(corpus_index, corpus, [clean_rel])

      options = build_options(
        root: corpus, audit: audit, registry: registry, output: output,
        geography: geography, singapore_plan: singapore_plan, corpus_index: corpus_index
      )
      AuditedLongPathRepair.new(options).run
      plan = JSON.parse(output.join("plan.json").read(encoding: "UTF-8"))
      row = plan.fetch("rows").find { |entry| entry["role"] == "legacy_clean_work_migration" }
      clean.join(".legacy_source.input").binwrite(stale_bytes)

      failing_class = Class.new(AuditedLongPathRepair) do
        private

        def migrate_legacy_single_document!(*args)
          raise IOError, "simulated failure after conflict isolation and backup"
        end
      end

      error = assert_raises(IOError) do
        failing_class.new(options.merge(apply: true)).run
      end
      assert_includes error.message, "simulated failure"

      assert clean.directory?
      assert_equal source_text, clean.join(source_name).read(encoding: "UTF-8")
      assert_equal "backup\n", clean.join(backup_name).read(encoding: "UTF-8")
      assert_equal stale_bytes, clean.join(".legacy_source.input").binread
      refute clean.join(".repair_conflict_001.input").exist?
      refute corpus.join(row.fetch("new_path")).exist?
    end
  end

  def test_clean_legacy_source_is_validated_by_body_size_when_index_excludes_headers
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      corpus = root.join("corpus")
      output = root.join("output")
      audit = root.join("audit.csv")
      registry = root.join("metadata_id_registry.csv")
      geography = root.join("geography.yml")
      singapore_plan = root.join("missing_plan.json")
      corpus_index = root.join("fanyahanwen-corpus_index.csv")
      output.mkpath
      corpus.mkpath
      write_registry(registry, [])
      write_geography_map(geography)

      title = "索引只記正文大小但現存舊檔仍含一千位元組標頭的長題名作品"
      clean_rel = "中國漢文/clean/宋朝/北宋/#{title}"
      clean = corpus.join(clean_rel)
      clean.mkpath
      source_name = "#{title}__juan_01.txt"

      body_prefix = "正文。\n"
      body = body_prefix + ("x" * (599 - body_prefix.bytesize))
      assert_equal 599, body.bytesize

      # Reproduce the live corpus relationship: the historical index says 599
      # bytes because it measured the searchable body, but the legacy TXT now
      # occupies 1653 bytes because it still carries 1054 bytes of # headers.
      clean.join(source_name).binwrite(body)
      write_audit(audit, [clean_rel])
      write_corpus_index(corpus_index, corpus, [clean_rel])

      preamble = "\r\n\r\n\uFEFF"
      fixed_headers = "# TITLE: #{title}\r\n# AUTHOR: 蘇軾\r\n"
      wrapper_bytes = "# NOTES: \r\n".bytesize
      padding = 1_054 - preamble.bytesize - fixed_headers.bytesize - wrapper_bytes
      assert_operator padding, :>, 0
      headers = preamble + fixed_headers + "# NOTES: " + ("h" * padding) + "\r\n"
      assert_equal 1_054, headers.bytesize
      legacy_source = headers + body
      assert_equal 1_653, legacy_source.bytesize
      clean.join(source_name).binwrite(legacy_source)

      options = build_options(
        root: corpus, audit: audit, registry: registry, output: output,
        geography: geography, singapore_plan: singapore_plan, corpus_index: corpus_index
      )
      AuditedLongPathRepair.new(options).run
      plan = JSON.parse(output.join("plan.json").read(encoding: "UTF-8"))
      row = plan.fetch("rows").find { |entry| entry["role"] == "legacy_clean_work_migration" }
      assert_equal 599, row.fetch("source_child_size_bytes")

      AuditedLongPathRepair.new(options.merge(apply: true)).run

      migrated = corpus.join(row.fetch("new_path"))
      assert_equal body, migrated.join("text.txt").read(encoding: "UTF-8")
      metadata = JSON.parse(migrated.join("metadata.json").read(encoding: "UTF-8"))
      assert_equal title, metadata.fetch("title")
      assert_equal ["蘇軾"], metadata.fetch("authors")

      report = CSV.read(
        output.join("migrated_legacy_works.csv"), headers: true, encoding: "bom|utf-8"
      ).first
      assert_equal "1653", report.fetch("legacy_source_size_bytes")
      assert_equal "599", report.fetch("indexed_source_size_bytes")
      assert_equal "599", report.fetch("body_size_bytes")
    end
  end

  def test_legacy_parser_handles_blank_crlf_preamble_and_bom_before_headers
    body = "正文第一行。\r\n正文第二行。\r\n"
    source = "\r\n\r\n\uFEFF# TITLE: 測試作品\r\n# NATION: 北宋\r\n" + body

    parsed = AuditedLongPathRepair.allocate.send(:parse_legacy_text, source)

    assert_equal body, parsed.fetch(:body)
    assert_equal ["測試作品"], parsed.fetch(:headers).fetch("TITLE")
    assert_equal ["北宋"], parsed.fetch(:headers).fetch("NATION")
    assert_equal 4, parsed.fetch(:header_line_count)
  end

  def test_legacy_parser_keeps_leading_blank_lines_when_there_is_no_header_block
    source = "\r\n\r\n\uFEFF正文。\r\n"

    parsed = AuditedLongPathRepair.allocate.send(:parse_legacy_text, source)

    assert_equal "\r\n\r\n正文。\r\n", parsed.fetch(:body)
    assert_empty parsed.fetch(:headers)
    assert_equal 0, parsed.fetch(:header_line_count)
  end

end
