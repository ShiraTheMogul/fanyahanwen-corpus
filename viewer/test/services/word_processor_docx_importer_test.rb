# frozen_string_literal: true

require "test_helper"
require "zip"

class WordProcessorDocxImporterTest < ActiveSupport::TestCase
  test "imports headings, paragraphs, comments, footnotes, tables, and title" do
    bytes = build_docx(
      "word/document.xml" => <<~XML,
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>序</w:t></w:r></w:p>
            <w:p>
              <w:commentRangeStart w:id="0"/>
              <w:r><w:t>臣聞</w:t></w:r>
              <w:commentRangeEnd w:id="0"/>
              <w:r><w:footnoteReference w:id="2"/></w:r>
              <w:r><w:t>木本</w:t></w:r>
            </w:p>
            <w:p><w:pPr><w:pStyle w:val="Heading2"/></w:pPr><w:r><w:t>第一章</w:t></w:r></w:p>
            <w:tbl><w:tr><w:tc><w:p><w:commentRangeStart w:id="1"/><w:r><w:t>甲</w:t></w:r><w:commentRangeEnd w:id="1"/></w:p></w:tc><w:tc><w:p><w:r><w:t>乙</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
          </w:body>
        </w:document>
      XML
      "word/comments.xml" => <<~XML,
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:comments xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:comment w:id="0"><w:p><w:r><w:t>Comment text</w:t></w:r></w:p></w:comment>
          <w:comment w:id="1"><w:p><w:r><w:t>Table comment</w:t></w:r></w:p></w:comment>
        </w:comments>
      XML
      "word/footnotes.xml" => <<~XML,
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:footnotes xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:footnote w:id="2"><w:p><w:r><w:t>Footnote text</w:t></w:r></w:p></w:footnote>
        </w:footnotes>
      XML
      "docProps/core.xml" => <<~XML
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:title>試文</dc:title>
        </cp:coreProperties>
      XML
    )

    result = WordProcessorDocxImporter.call(StringIO.new(bytes))

    assert_equal "試文", result.fetch("title")
    assert_equal ["序", "第一章"], result.fetch("chapters").map { |chapter| chapter.fetch("title") }
    assert_equal "臣聞木本", result.fetch("chapters").first.fetch("text")
    assert_equal "甲	乙", result.fetch("chapters").last.fetch("text")

    annotations = result.fetch("chapters").first.fetch("annotations")
    assert_equal ["comment", "footnote"], annotations.map { |annotation| annotation.fetch("kind") }
    assert_equal "Comment text", annotations.first.fetch("note")
    assert_equal [0, 2], annotations.first.values_at("start", "end")
    assert_equal "Footnote text", annotations.last.fetch("note")
    assert_equal [2, 2], annotations.last.values_at("start", "end")

    table_annotations = result.fetch("chapters").last.fetch("annotations")
    assert_equal 1, table_annotations.length
    assert_equal "Table comment", table_annotations.first.fetch("note")
    assert_equal [0, 1], table_annotations.first.values_at("start", "end")
  end

  test "uses one chapter when the DOCX has no headings" do
    bytes = build_docx(
      "word/document.xml" => <<~XML
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:r><w:t>天地玄黃</w:t></w:r></w:p>
            <w:p><w:r><w:t>宇宙洪荒</w:t></w:r></w:p>
          </w:body>
        </w:document>
      XML
    )

    result = WordProcessorDocxImporter.call(StringIO.new(bytes))

    assert_equal 1, result.fetch("chapters").length
    assert_equal "Chapter 1", result.fetch("chapters").first.fetch("title")
    assert_equal "天地玄黃
宇宙洪荒", result.fetch("chapters").first.fetch("text")
  end

  private

  def build_docx(entries)
    buffer = Zip::OutputStream.write_buffer do |zip|
      entries.each do |path, content|
        zip.put_next_entry(path)
        zip.write(content)
      end
    end
    buffer.string
  end
end
