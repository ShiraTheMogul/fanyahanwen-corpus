require_relative "../test_helper"
require "fileutils"
require "tmpdir"

class CorpusFsSortingTest < ActiveSupport::TestCase
  class ReverseSorter
    attr_reader :prepared

    def prepare(names)
      @prepared = names.dup
      self
    end

    def key(name)
      name.each_byte.map { |byte| -byte }
    end
  end

  setup do
    @root = Pathname.new(Dir.mktmpdir("corpus-fs-sorting"))
    @root.join("a.txt").write("a")
    @root.join("b.txt").write("b")
    @root.join("c.txt").write("c")
  end

  teardown do
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "prepares a custom sorter once and uses it before directory pagination" do
    sorter = ReverseSorter.new
    fs = CorpusFs.new(root: @root)

    page = fs.list_dir_page(@root.to_s, page: 1, per_page: 2, sorter: sorter)

    assert_equal %w[c.txt b.txt], page.items
    assert_equal %w[a.txt b.txt c.txt].sort, sorter.prepared.sort
  end

  test "literal raw directories are hidden case-insensitively but raw.txt remains visible" do
    @root.join("raw").mkdir
    @root.join("RAW").mkdir
    @root.join("raw.txt").write("visible")
    fs = CorpusFs.new(root: @root)

    assert_equal %w[a.txt b.txt c.txt raw.txt], fs.list_dir(@root.to_s)

    page = fs.list_dir_page(@root.to_s, page: 1, per_page: 10)
    assert_equal %w[a.txt b.txt c.txt raw.txt], page.items
    assert_equal 4, page.raw_total
  end

  test "entry filtering happens before a custom sorter is prepared" do
    @root.join("visible").mkdir
    @root.join("archive").mkdir
    sorter = ReverseSorter.new
    fs = CorpusFs.new(root: @root)
    only_public = ->(name) { name == "visible" }

    result = fs.list_dir(@root.to_s, sorter: sorter, entry_filter: only_public)

    assert_equal ["visible"], result
    assert_equal ["visible"], sorter.prepared
  end

  test "entry filtering is respected by pagination threshold counting" do
    @root.join("visible").mkdir
    @root.join("archive").mkdir
    fs = CorpusFs.new(root: @root)
    only_public = ->(name) { name == "visible" }

    refute fs.more_than_entries?(@root.to_s, 1, entry_filter: only_public)
    assert fs.more_than_entries?(@root.to_s, 0, entry_filter: only_public)
  end

end
