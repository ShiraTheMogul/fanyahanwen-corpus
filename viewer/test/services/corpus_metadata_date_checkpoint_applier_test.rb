# frozen_string_literal: true

require_relative "../test_helper"
require "csv"
require "fileutils"
require "json"
require "tmpdir"

class CorpusMetadataDateCheckpointApplierTest < ActiveSupport::TestCase
  setup do
    @root = Pathname(Dir.mktmpdir("corpus-metadata-date-checkpoint"))
    @report_root = @root.join("reports")
    @report_path = @root.join("dates.tsv")
  end

  teardown do
    FileUtils.rm_rf(@root)
  end

  test "applies date-label and polity checkpoint rows without reading corpus text" do
    exact = write_metadata("中國漢文/clean/明朝/大明/某序", title: "某序", period: "明朝", polity: "大明")
    broad = write_metadata("中國漢文/clean/宋朝/北宋/某集", title: "某集", period: "宋朝", polity: "宋")
    write_report([
      row_for(exact, action: "date_label", title: "某序", period: "明朝", polity: "大明", date: "1544年"),
      row_for(broad, action: "polity_ca", title: "某集", period: "宋朝", polity: "宋", ca: "960–1279年", start_year: 960, end_year: 1279)
    ])

    result = run_checkpoint(apply: true)

    assert_equal "1544年", read_metadata(exact)["date"]
    assert_equal "960–1127年", read_metadata(broad)["ca"]
    assert_equal 2, result.written
    assert_equal 1, result.folder_overrides
  end

  test "author checkpoint must overlap the already-arranged folder chronology" do
    accepted = write_metadata("中國漢文/clean/明朝/大明/明人文", title: "明人文", period: "", polity: "")
    rejected = write_metadata("中國漢文/clean/中華民國/民國文", title: "民國文", period: "", polity: "")
    write_report([
      row_for(accepted, action: "author_ca", title: "明人文", ca: "1409–1469年", start_year: 1409, end_year: 1469),
      row_for(rejected, action: "author_ca", title: "民國文", ca: "1420年", start_year: 1420, end_year: 1420)
    ])

    result = run_checkpoint(apply: true)

    assert_equal "1409–1469年", read_metadata(accepted)["ca"]
    assert_nil read_metadata(rejected)["ca"]
    assert_equal 1, result.written
    assert_equal 1, result.author_path_rejected
  end

  test "self-regnal rows remain deferred and existing chronology is never overwritten" do
    self_regnal = write_metadata("中國漢文/clean/明朝/大明/某詔", title: "某詔", period: "明朝", polity: "大明")
    locked = write_metadata(
      "中國漢文/clean/明朝/大明/已有日期",
      title: "已有日期",
      period: "明朝",
      polity: "大明",
      extra: { "date" => "1500年" }
    )
    write_report([
      row_for(self_regnal, action: "self_regnal", title: "某詔", period: "明朝", polity: "大明", date: "1544年"),
      row_for(locked, action: "polity_ca", title: "已有日期", period: "明朝", polity: "大明", ca: "1368–1644年", start_year: 1368, end_year: 1644)
    ])

    result = run_checkpoint(apply: true)

    assert_nil read_metadata(self_regnal)["date"]
    assert_equal "1500年", read_metadata(locked)["date"]
    assert_nil read_metadata(locked)["ca"]
    assert_equal 1, result.deferred_self_regnal
    assert_equal 1, result.already_chronologized
  end



  test "folder chronology wins when old metadata category residue points at another dynasty" do
    path = write_metadata(
      "中國漢文/clean/南北朝/劉宋/某經",
      title: "某經",
      period: "宋朝",
      polity: "宋"
    )
    write_report([
      row_for(path, action: "polity_ca", title: "某經", period: "宋朝", polity: "宋", ca: "960–1279年", start_year: 960, end_year: 1279)
    ])

    result = run_checkpoint(apply: true)

    repaired = read_metadata(path)
    assert_equal "420–589年", repaired["ca"]
    assert_equal "南北朝", repaired["period"]
    assert_equal "劉宋", repaired["polity"]
    assert_equal 1, result.folder_overrides
    assert_equal 1, result.folder_conflicts
    assert_equal 1, result.period_repairs
    assert_equal 1, result.polity_repairs
  end


  test "conflicting path repair understands Warring States polity folders" do
    path = write_metadata(
      "中國漢文/clean/周朝/東周/戰國時代/魏/某書",
      title: "某書",
      period: "漢朝",
      polity: "漢"
    )
    write_report([
      row_for(path, action: "polity_ca", title: "某書", period: "漢朝", polity: "漢", ca: "前206–220年", start_year: -206, end_year: 220)
    ])

    run_checkpoint(apply: true)

    repaired = read_metadata(path)
    assert_equal "前475–前256年", repaired["ca"]
    assert_equal "戰國時代", repaired["period"]
    assert_equal "魏", repaired["polity"]
  end

  test "conflicting path repair preserves dynasty subgroup metadata conventions" do
    south_song = write_metadata(
      "中國漢文/clean/宋朝/南宋/某書",
      title: "某書",
      period: "漢朝",
      polity: "漢"
    )
    qing = write_metadata(
      "中國漢文/clean/清朝/大清/某集",
      title: "某集",
      period: "漢朝",
      polity: "漢"
    )
    write_report([
      row_for(south_song, action: "polity_ca", title: "某書", period: "漢朝", polity: "漢", ca: "前206–220年", start_year: -206, end_year: 220),
      row_for(qing, action: "polity_ca", title: "某集", period: "漢朝", polity: "漢", ca: "前206–220年", start_year: -206, end_year: 220)
    ])

    run_checkpoint(apply: true)

    song_metadata = read_metadata(south_song)
    assert_equal "南宋", song_metadata["period"]
    assert_equal "宋", song_metadata["polity"]

    qing_metadata = read_metadata(qing)
    assert_equal "清朝", qing_metadata["period"]
    assert_equal "大清", qing_metadata["polity"]
  end

  test "rerun can finish folder metadata repair after ca was already written" do
    path = write_metadata(
      "中國漢文/clean/南北朝/劉宋/某經",
      title: "某經",
      period: "宋朝",
      polity: "宋",
      extra: { "ca" => "420–589年" }
    )
    write_report([
      row_for(path, action: "polity_ca", title: "某經", period: "宋朝", polity: "宋", ca: "960–1279年", start_year: 960, end_year: 1279)
    ])

    result = run_checkpoint(apply: true)

    repaired = read_metadata(path)
    assert_equal "420–589年", repaired["ca"]
    assert_equal "南北朝", repaired["period"]
    assert_equal "劉宋", repaired["polity"]
    assert_equal 1, result.already_chronologized
    assert_equal 1, result.written
  end

  test "path chronology ignores a later dynastic homonym inside an ancient hierarchy" do
    path = write_metadata(
      "中國漢文/clean/周朝/東周/戰國時代/宋/某篇",
      title: "某篇",
      period: "",
      polity: ""
    )
    write_report([
      row_for(path, action: "polity_ca", title: "某篇", ca: "前1600–前221年", start_year: -1600, end_year: -221)
    ])

    run_checkpoint(apply: true)

    assert_equal "前475–前256年", read_metadata(path)["ca"]
  end

  test "a report row is rejected if metadata changed after the long audit" do
    path = write_metadata("中國漢文/clean/唐朝/某書", title: "新題", period: "唐朝", polity: "唐")
    write_report([
      row_for(path, action: "polity_ca", title: "舊題", period: "唐朝", polity: "唐", ca: "618–907年", start_year: 618, end_year: 907)
    ])

    result = run_checkpoint(apply: true)

    assert_nil read_metadata(path)["ca"]
    assert_equal 1, result.stale
  end

  private

  def run_checkpoint(apply:)
    CorpusMetadataDateCheckpointApplier.new(
      root: @root,
      report_path: @report_path,
      apply: apply,
      logger: nil,
      progress_every: 100_000,
      report_root: @report_root
    ).run!
  end

  def write_metadata(relative_folder, title:, period:, polity:, extra: {})
    folder = @root.join(relative_folder)
    FileUtils.mkdir_p(folder)
    metadata = {
      "schema_version" => 1,
      "title" => title,
      "period" => period,
      "polity" => polity,
      "is_compilation" => false,
      "documents" => []
    }.merge(extra)
    path = folder.join("metadata.json")
    write_json(path, metadata)
    path
  end

  def write_report(rows)
    headers = %w[path action title period polity date ca evidence evidence_year evidence_start evidence_end]
    File.open(@report_path, "wb") do |io|
      io.write("\xEF\xBB\xBF".b)
      csv = CSV.new(io, col_sep: "\t", write_headers: true, headers: headers)
      rows.each { |row| csv << headers.map { |header| row[header] } }
      csv.close
    end
  end

  def row_for(path, action:, title:, period: "", polity: "", date: "", ca: "", start_year: "", end_year: "")
    {
      "path" => path.relative_path_from(@root).to_s.tr("\\", "/"),
      "action" => action,
      "title" => title,
      "period" => period,
      "polity" => polity,
      "date" => date,
      "ca" => ca,
      "evidence" => action,
      "evidence_year" => "",
      "evidence_start" => start_year,
      "evidence_end" => end_year
    }
  end

  def write_json(path, metadata)
    path.binwrite("\xEF\xBB\xBF".b + (JSON.pretty_generate(metadata) + "\n").encode(Encoding::UTF_8).b)
  end

  def read_metadata(path)
    raw = path.binread
    assert raw.start_with?("\xEF\xBB\xBF".b)
    JSON.parse(raw.force_encoding(Encoding::UTF_8).sub(/\A\uFEFF/, ""))
  end
end
