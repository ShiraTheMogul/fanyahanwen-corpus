# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "json"
require "tmpdir"

class CorpusMetadataAutoDaterTest < ActiveSupport::TestCase
  FakeResolution = Struct.new(:year_start, :year_end, :authority_kind, :date_label, :authority_name) do
    def resolved? = !year_start.nil? || !year_end.nil?
  end

  class FakeResolver
    def resolve(metadata:)
      text = metadata.to_h["date_text"].to_s
      return FakeResolution.new(1544, 1544, "era", "嘉靖二十三年", "嘉靖") if text.include?("嘉靖二十三年")
      nil
    end
  end

  class FakeStore
    def historical_available? = false
  end

  CandidateSet = Struct.new(:candidates)

  class FakePeople
    def initialize(rows = {})
      @rows = rows
    end

    def find_candidates(names:, metadata: {})
      CandidateSet.new(Array(@rows[names.first]))
    end
  end

  setup do
    @root = Pathname(Dir.mktmpdir("corpus-metadata-auto-dater"))
    @report_root = @root.join("reports")
  end

  teardown do
    FileUtils.rm_rf(@root)
  end

  test "writes one exact date from a self-referential regnal date" do
    metadata_path = write_work(
      title: "某書序",
      text: "昔人有言。嘉靖二十三年八月，愚乃為之序。"
    )

    run_dater(person_repository: FakePeople.new)

    raw = metadata_path.binread
    assert raw.start_with?("\xEF\xBB\xBF".b)
    metadata = JSON.parse(raw.force_encoding(Encoding::UTF_8).sub(/\A\uFEFF/, ""))
    assert_equal "1544年", metadata["date"]
    assert_nil metadata["ca"]
    assert_nil metadata["year"]
  end

  test "a narrative regnal date does not become the work date" do
    metadata_path = write_work(
      title: "某事記",
      text: "嘉靖二十三年，王公至郡。其後事具載於此。"
    )

    run_dater(person_repository: FakePeople.new)

    metadata = read_metadata(metadata_path)
    assert_nil metadata["date"]
    assert_equal "1368–1644年", metadata["ca"]
  end

  test "author range has priority over polity fallback" do
    metadata_path = write_work(
      title: "無年序",
      authors: [{ "name" => "劉定之", "role" => "author" }],
      text: "夫文章之作，其來久矣。"
    )
    people = FakePeople.new(
      "劉定之" => [{
        "id" => "1",
        "label" => "劉定之",
        "year_start" => 1409,
        "year_end" => 1469,
        "polity" => "明",
        "confidence" => "high"
      }]
    )

    run_dater(person_repository: people)

    metadata = read_metadata(metadata_path)
    assert_equal "1409–1469年", metadata["ca"]
  end

  test "existing exact date is never overwritten" do
    metadata_path = write_work(
      title: "已有日期",
      extra: { "date" => "1500年" },
      text: "嘉靖二十三年八月，愚乃為之序。"
    )

    run_dater(person_repository: FakePeople.new)

    metadata = read_metadata(metadata_path)
    assert_equal "1500年", metadata["date"]
    assert_nil metadata["ca"]
  end

  test "sexagenary arithmetic supports an era anchor followed by a bare self date" do
    dater = build_dater(person_repository: FakePeople.new)
    assert_equal [1542], dater.send(:sexagenary_years, "壬寅", 1522, 1566)
    assert_equal [1544], dater.send(:sexagenary_years, "甲辰", 1522, 1566)
  end

  test "multiple authors use only their overlapping chronology" do
    metadata_path = write_work(
      title: "合撰",
      authors: [{ "name" => "甲" }, { "name" => "乙" }],
      text: "合撰一篇。"
    )
    people = FakePeople.new(
      "甲" => [{ "id" => "1", "year_start" => 1400, "year_end" => 1450, "polity" => "明", "confidence" => "high" }],
      "乙" => [{ "id" => "2", "year_start" => 1430, "year_end" => 1480, "polity" => "明", "confidence" => "high" }]
    )

    run_dater(person_repository: people)

    assert_equal "1430–1450年", read_metadata(metadata_path)["ca"]
  end

  private

  def run_dater(person_repository:)
    build_dater(person_repository: person_repository).run!
  end

  def build_dater(person_repository:)
    CorpusMetadataAutoDater.new(
      root: @root,
      store: FakeStore.new,
      person_repository: person_repository,
      resolver: FakeResolver.new,
      logger: nil,
      apply: true,
      apply_moves: false,
      report_root: @report_root,
      progress_every: 10_000
    )
  end

  def write_work(title:, text:, authors: nil, extra: {})
    folder = @root.join("中國漢文", "clean", "明朝", "大明", title)
    FileUtils.mkdir_p(folder)
    text_file = "#{title}.txt"
    metadata = {
      "schema_version" => 1,
      "work_id" => rand(1_000_000),
      "corpus_root" => "中國漢文",
      "macro_region" => "中國",
      "period" => "明朝",
      "polity" => "大明",
      "title" => title,
      "work_base_title" => title,
      "is_compilation" => false,
      "documents" => [{ "document_id" => rand(1_000_000), "file" => text_file }],
      "known_commentaries" => []
    }
    metadata["authors"] = authors if authors
    metadata.merge!(extra)
    metadata_path = folder.join("metadata.json")
    metadata_path.binwrite("\xEF\xBB\xBF".b + (JSON.pretty_generate(metadata) + "\n").encode(Encoding::UTF_8).b)
    folder.join(text_file).binwrite("\xEF\xBB\xBF".b + text.encode(Encoding::UTF_8).b)
    metadata_path
  end

  def read_metadata(path)
    JSON.parse(path.binread.force_encoding(Encoding::UTF_8).sub(/\A\uFEFF/, ""))
  end
end
