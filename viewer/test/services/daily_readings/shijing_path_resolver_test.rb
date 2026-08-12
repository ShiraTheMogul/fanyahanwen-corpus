require_relative "../../test_helper"
require "fileutils"
require "json"
require "tmpdir"

class DailyReadingsShijingPathResolverTest < ActiveSupport::TestCase
  setup do
    @root = Pathname.new(Dir.mktmpdir("shijing-path-resolver"))
    @cache_root = @root.join("cache")
    @work = @root.join("shijing", "work")
    FileUtils.mkdir_p(@work)
    @work.join("poem.txt").write("詩")
    @work.join("metadata.json").write(JSON.generate(
      "title" => "poem",
      "documents" => [{
        "file" => "poem.txt",
        "identifiers" => [{ "scheme" => "mao_no", "value" => 1 }]
      }]
    ))
  end

  teardown do
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "persists the Mao path catalogue and reuses it without rescanning metadata" do
    resolver = DailyReadings::ShijingPathResolver.new(
      corpus_root: @root,
      shijing_root_relative: "shijing",
      cache_root: @cache_root,
      logger: nil
    )

    assert_equal "shijing/work/poem.txt", resolver.resolve_values(stored_path: "stale.txt", mao_no: 1)
    assert @cache_root.join(DailyReadings::ShijingPathResolver::CACHE_FILENAME).file?

    @work.join("metadata.json").delete
    cached_resolver = DailyReadings::ShijingPathResolver.new(
      corpus_root: @root,
      shijing_root_relative: "shijing",
      cache_root: @cache_root,
      logger: nil
    )

    assert_equal "shijing/work/poem.txt", cached_resolver.resolve_values(stored_path: "stale.txt", mao_no: 1)
  end
end
