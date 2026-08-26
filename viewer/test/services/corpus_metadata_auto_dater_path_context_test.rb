# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "tmpdir"

class CorpusMetadataAutoDaterPathContextTest < ActiveSupport::TestCase
  class FakeStore
    def historical_available? = false
  end

  setup do
    @root = Pathname(Dir.mktmpdir("corpus-metadata-auto-dater-path"))
    @dater = CorpusMetadataAutoDater.new(
      root: @root,
      store: FakeStore.new,
      person_repository: Object.new,
      resolver: Object.new,
      logger: nil,
      apply: false,
      report_root: @root.join("reports")
    )
  end

  teardown do
    FileUtils.rm_rf(@root)
  end

  test "folder chronology rejects an author candidate from a different era" do
    path = @root.join("中國漢文", "clean", "中華民國", "某文", "metadata.json")
    candidate = {
      "year_start" => 1420,
      "year_end" => 1420,
      "polity" => "明"
    }

    refute @dater.send(:person_candidate_compatible?, candidate, {}, path)
  end

  test "folder chronology supplies polity fallback when metadata omitted it" do
    path = @root.join("中國漢文", "clean", "宋朝", "北宋", "某集", "metadata.json")

    result = @dater.send(:polity_circa, { "period" => "宋朝", "polity" => "宋" }, path)

    assert_equal "polity_ca", result[:kind]
    assert_equal 960, result[:start]
    assert_equal 1127, result[:end]
    assert_equal "北宋", result[:polity]
  end

  test "ancient polity names do not get mistaken for later dynasties in folder context" do
    path = @root.join("中國漢文", "clean", "周朝", "東周", "戰國時代", "宋", "某篇", "metadata.json")

    result = @dater.send(:polity_circa, {}, path)

    assert_equal(-475, result[:start])
    assert_equal(-256, result[:end])
  end
end
