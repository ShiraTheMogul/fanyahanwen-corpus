require_relative "../../test_helper"

class CorpusSearchDocumentReaderTest < ActiveSupport::TestCase
  test "removes a normal metadata header and separator lines" do
    result = CorpusSearch::DocumentReader.parse("# TITLE: 詩經\n# UNKNOWN_FIELD: retained\n\n關關雎鳩\n")

    assert_equal "詩經", result.metadata["title"]
    assert_equal "retained", result.metadata["unknown_field"]
    assert_equal "關關雎鳩\n", result.body
  end

  test "handles a BOM and blank lines before metadata" do
    raw = "\uFEFF\r\n\r\n# AUTHOR: 無名氏\r\n# TIMES: 西周\r\n\r\n正文\r\n"
    result = CorpusSearch::DocumentReader.parse(raw)

    assert_equal "無名氏", result.metadata["author"]
    assert_equal "西周", result.metadata["period"]
    assert_equal "正文\r\n", result.body
  end

  test "preserves a file with no metadata as body text" do
    raw = "\n正文第一行\n# 此行不是初始標頭\n"
    result = CorpusSearch::DocumentReader.parse(raw)

    assert_empty result.metadata
    assert_equal raw, result.body
  end

  test "returns an empty body for a header-only file" do
    result = CorpusSearch::DocumentReader.parse("# TITLE: 空檔\n# AUTHOR: 無名氏\n")

    assert_equal "空檔", result.metadata["title"]
    assert_equal "", result.body
  end

  test "metadata-only text never leaks into the body" do
    result = CorpusSearch::DocumentReader.parse("# TITLE: 關關雎鳩\n# REFERENCE: 關關雎鳩\n\n在河之洲\n")

    assert_not_includes result.body, "關關雎鳩"
    assert_equal [0], CorpusSearch::SearchText.positions_of(result.body, "在河之洲")
    assert_empty CorpusSearch::SearchText.positions_of(result.body, "關關雎鳩")
  end

  test "body fingerprint depends only on searchable body" do
    first = CorpusSearch::DocumentReader.parse("# TITLE: First\n\n正文\n")
    second = CorpusSearch::DocumentReader.parse("# TITLE: Second\n\n正文\n")

    assert_equal first.body_fingerprint, second.body_fingerprint
  end
end
