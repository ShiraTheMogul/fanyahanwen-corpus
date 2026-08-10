require_relative "../test_helper"
require "stringio"
require "tempfile"

class Utf8StreamTest < ActiveSupport::TestCase
  test "opens a local UTF-8 file with a BOM" do
    Tempfile.create("utf8-stream") do |file|
      file.binmode
      file.write("\xEF\xBB\xBF清\n".b)
      file.flush

      stream = CharacterData::Utf8Stream.open(path: file.path)
      assert_equal Encoding::UTF_8, stream.external_encoding
      assert_equal "\uFEFF清\n", stream.gets
    ensure
      stream&.close
    end
  end

  test "opens a remote stream in binary mode before assigning UTF-8" do
    raw = StringIO.new("\xEF\xBB\xBF清\n".b)
    opener = proc do |_url, mode, read_timeout:, **_options|
      assert_equal "rb", mode
      assert_equal 60, read_timeout
      raw
    end

    URI.stub(:open, opener) do
      stream = CharacterData::Utf8Stream.open(url: "https://example.test/data.txt")
      assert_equal Encoding::UTF_8, stream.external_encoding
      assert_equal "\uFEFF清\n", stream.gets
    ensure
      stream&.close
    end
  end
end
