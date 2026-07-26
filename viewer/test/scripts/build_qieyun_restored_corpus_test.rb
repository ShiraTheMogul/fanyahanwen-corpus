# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require Rails.root.join("script/build_qieyun_restored_corpus").to_s

class BuildQieyunRestoredCorpusTest < ActiveSupport::TestCase
  HEADERS = %w[頁 行 音韻地位描述 聲調 韻目 序数 小韻 音類 字頭 釋義].freeze

  test "builds two readable reconstruction editions and line maps" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      source = root.join("qieyun-restored")
      output = root.join("output")
      source.mkpath

      write_csv(source.join("切韻 藤田拓海復元.csv"), [
        [1, 1, "端一東平", "平", "東", 1, 1, "端1", "東", "徳紅反.二."],
        [1, 3, "端一東平", "平", "東", 3, 1, "端1", "涷", "水名."],
        [1, 5, "定一東平", "平", "東", 5, 2, "定1", "同", "徒紅反.十六."],
        [1, 7, "定一東平", "平", "東", 7, 2, "定1", "銅", "."]
      ])
      write_csv(source.join("切韻 李永富復元.csv"), [
        [1, 1, "端一東平", "平", "東", 1, 1, "端1", "東", "徳紅反.二."],
        [1, 3, "端一東平", "平", "東", 3, 1, "端1", "涷", "水名."],
        [1, 5, "定一東平", "平", "東", 5, 2, "定1", "同", "徒紅反.十六."],
        [1, 7, "定一東平", "平", "東", 7, 2, "定1", "銅", "."]
      ])

      summary = QieyunRestoredCorpus::Builder.new(
        source_dir: source,
        output_dir: output,
        source_revision: "abc123"
      ).build

      assert_equal false, summary["apply_ready"]
      assert_equal 2, summary["editions"].length
      overlay = output.join("review_only_corpus_overlay/中國漢文/clean/隋朝/隋/切韻")
      fujita_text = overlay.join("reconstruction/藤田拓海/切韻（藤田拓海復元本）.txt").read(encoding: "UTF-8")

      assert fujita_text.start_with?("平聲\n"), fujita_text.lines.first(5).join
      refute_includes fujita_text, "藤田拓海復元本"
      refute_includes fujita_text, "復元者："
      assert_includes fujita_text, "平聲"
      assert_includes fujita_text, "東韻"
      assert_includes fujita_text, "○東〈徳紅反.二.〉"
      assert_includes fujita_text, "涷〈水名.〉"
      assert_includes fujita_text, "○同〈徒紅反.十六.〉"
      assert_includes fujita_text, "銅\n"
      refute_includes fujita_text, "銅〈.〉"

      metadata = JSON.parse(overlay.join("metadata.json").read(encoding: "UTF-8"))
      assert_nil metadata["work_id"]
      assert_equal 2, metadata["editions"].length
      assert_equal "reconstruction", metadata.dig("editions", 0, "material_type")
      assert_equal true, metadata.dig("editions", 0, "reconstruction")
      assert_equal "藤田拓海", metadata.dig("editions", 0, "editors", 0, "name")
      assert_equal "reconstruction editor", metadata.dig("editions", 0, "editors", 0, "role")
      assert_equal "nk2028", metadata.dig("editions", 0, "contributors", 0, "name")
      assert_equal "abc123", metadata.dig("editions", 0, "documents", 0, "source_revision")

      map = CSV.read(output.join("reports/fujita_line_map.csv"), headers: true)
      assert_equal 4, map.length
      assert_equal "5", map[0]["output_line"]
      assert_equal "true", map[0]["group_head"]
      assert_equal "false", map[1]["group_head"]
      assert_equal "true", map[2]["group_head"]
      assert_equal ".", map[3]["definition"]
      assert_equal "", map[3]["rendered_definition"]
    end
  end

  test "emits an apply-ready overlay when all stable ids are supplied" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      source = root.join("qieyun-restored")
      output = root.join("output")
      source.mkpath
      row = [[1, 1, "端一東平", "平", "東", 1, 1, "端1", "東", "徳紅反.二."]]
      write_csv(source.join("切韻 藤田拓海復元.csv"), row)
      write_csv(source.join("切韻 李永富復元.csv"), row)

      summary = QieyunRestoredCorpus::Builder.new(
        source_dir: source,
        output_dir: output,
        ids: {
          work_id: 100,
          fujita_edition_id: 101,
          fujita_document_id: 102,
          li_edition_id: 103,
          li_document_id: 104
        }
      ).build

      assert_equal true, summary["apply_ready"]
      metadata_path = output.join("corpus_overlay/中國漢文/clean/隋朝/隋/切韻/metadata.json")
      metadata = JSON.parse(metadata_path.read(encoding: "UTF-8"))
      assert_equal 100, metadata["work_id"]
      assert_equal 101, metadata.dig("editions", 0, "edition_id")
      assert_equal 104, metadata.dig("editions", 1, "documents", 0, "document_id")
    end
  end


  test "detects the source git revision when no revision option is supplied" do
    skip "git is unavailable" unless system("git --version >/dev/null 2>&1")

    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      source = root.join("qieyun-restored")
      output = root.join("output")
      source.mkpath
      row = [[1, 1, "端一東平", "平", "東", 1, 1, "端1", "東", "徳紅反.二."]]
      write_csv(source.join("切韻 藤田拓海復元.csv"), row)
      write_csv(source.join("切韻 李永富復元.csv"), row)

      system("git", "-C", source.to_s, "init", "-q", exception: true)
      system("git", "-C", source.to_s, "config", "user.email", "test@example.invalid", exception: true)
      system("git", "-C", source.to_s, "config", "user.name", "Test", exception: true)
      system("git", "-C", source.to_s, "add", ".", exception: true)
      system("git", "-C", source.to_s, "commit", "-qm", "fixture", exception: true)
      expected = Open3.capture2("git", "-C", source.to_s, "rev-parse", "HEAD").first.strip

      summary = QieyunRestoredCorpus::Builder.new(
        source_dir: source,
        output_dir: output
      ).build

      assert_equal expected, summary["source_revision"]
      metadata = JSON.parse(
        output.join("review_only_corpus_overlay/中國漢文/clean/隋朝/隋/切韻/metadata.json").read(encoding: "UTF-8")
      )
      assert_equal expected, metadata.dig("sources", 0, "revision")
    end
  end

  private

  def write_csv(path, rows)
    CSV.open(path, "wb", write_headers: true, headers: HEADERS) do |csv|
      rows.each { |row| csv << row }
    end
  end
end
