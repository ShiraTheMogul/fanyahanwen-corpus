require_relative "../test_helper"
require "fileutils"
require "tmpdir"

class CorpusFsTest < ActiveSupport::TestCase
  CapturingLogger = Struct.new(:warnings) do
    def warn(message)
      warnings << message
    end
  end

  setup do
    @root = Pathname.new(Dir.mktmpdir("corpus-fs"))
  end

  teardown do
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "marks malformed UTF-8 visibly and warns once per path" do
    path = @root.join("bad.txt")
    path.binwrite("正\xFF文".b)
    logger = CapturingLogger.new([])
    fs = CorpusFs.new(root: @root, logger: logger)

    first_read = fs.read_text(path.to_s)
    second_read = fs.read_text(path.to_s)

    assert_equal "正\uFFFD文", first_read
    assert_equal first_read, second_read
    assert first_read.valid_encoding?
    assert_equal 1, logger.warnings.length
    assert_includes logger.warnings.first, "bad.txt"
    assert_includes logger.warnings.first, "U+FFFD"
  end

  test "removes a UTF-8 byte-order mark" do
    path = @root.join("bom.txt")
    path.binwrite("\xEF\xBB\xBF正文".b)

    assert_equal "正文", CorpusFs.new(root: @root).read_text(path.to_s)
  end
end
