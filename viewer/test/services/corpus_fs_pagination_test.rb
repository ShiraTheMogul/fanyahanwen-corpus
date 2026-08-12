require_relative "../test_helper"
require "fileutils"
require "tmpdir"

class CorpusFsPaginationTest < ActiveSupport::TestCase
  setup do
    @root = Pathname.new(Dir.mktmpdir("corpus-fs-pagination"))
    450.times { |index| @root.join(format("d%04d", index)).mkdir }
    @root.join("metadata.json").write("{}")
    @root.join("z.txt").write("正文")
    @fs = CorpusFs.new(root: @root)
  end

  teardown do
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "detects a large directory without requiring an exact count" do
    assert @fs.more_than_entries?(@root.to_s, 100)
    refute @fs.more_than_entries?(@root.to_s, 1_000)
  end

  test "paginates raw directory names before classifying entries" do
    page = @fs.list_dir_page(@root.to_s, page: 2, per_page: 200)

    assert_equal 2, page.page
    assert_equal 200, page.items.length
    assert_equal 452, page.raw_total
    assert_equal 3, page.total_pages
    refute_includes page.items, "metadata.json"
  end
end
