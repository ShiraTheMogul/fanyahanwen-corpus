# frozen_string_literal: true

require "nokogiri"
require "securerandom"
require "stringio"
require "zip"

# Structural DOCX importer for the Word Processor.
#
# The editor stores plain Unicode text plus semantic annotations. Word-specific
# presentation such as fonts, colours, page dimensions, and run styling is
# deliberately ignored. Heading paragraphs become chapters; ordinary paragraphs
# become body text; tables are flattened as tab-separated rows. Word comments and
# footnotes are retained as notes anchored to the nearest imported text position.
class WordProcessorDocxImporter
  WORD_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
  DC_NS = "http://purl.org/dc/elements/1.1/"

  def self.call(upload)
    new(upload).call
  end

  def initialize(upload)
    @upload = upload
  end

  def call
    bytes = read_upload
    Zip::File.open_buffer(StringIO.new(bytes)) do |zip|
      document = xml_entry(zip, "word/document.xml", required: true)
      comments = comment_lookup(zip)
      footnotes = footnote_lookup(zip)
      title = document_title(zip)

      chapters = import_body(document, comments:, footnotes:)
      chapters = [blank_chapter(title.presence || "Chapter 1")] if chapters.empty?

      {
        "version" => 1,
        "title" => title.to_s,
        "chapters" => chapters
      }
    end
  rescue Zip::Error, Nokogiri::XML::SyntaxError => e
    raise ArgumentError, "The DOCX file could not be read: #{e.message}"
  end

  private

  def read_upload
    io = @upload.respond_to?(:tempfile) ? @upload.tempfile : @upload
    io.rewind if io.respond_to?(:rewind)
    io.read
  end

  def xml_entry(zip, path, required: false)
    entry = zip.find_entry(path)
    if entry.nil?
      raise ArgumentError, "The DOCX archive is missing #{path}." if required
      return nil
    end

    Nokogiri::XML(entry.get_input_stream.read) { |config| config.strict.nonet }
  end

  def document_title(zip)
    doc = xml_entry(zip, "docProps/core.xml")
    return "" unless doc

    doc.at_xpath("//dc:title", "dc" => DC_NS)&.text.to_s.strip
  end

  def comment_lookup(zip)
    doc = xml_entry(zip, "word/comments.xml")
    return {} unless doc

    doc.xpath("//w:comment", "w" => WORD_NS).to_h do |node|
      id = node["w:id"] || node.attribute_with_ns("id", WORD_NS)&.value
      [id.to_s, paragraph_texts(node).join("\n").strip]
    end
  end

  def footnote_lookup(zip)
    doc = xml_entry(zip, "word/footnotes.xml")
    return {} unless doc

    doc.xpath("//w:footnote", "w" => WORD_NS).each_with_object({}) do |node, out|
      id = node["w:id"] || node.attribute_with_ns("id", WORD_NS)&.value
      next if id.to_s.start_with?("-")

      text = paragraph_texts(node).join("\n").strip
      out[id.to_s] = text if text.present?
    end
  end

  def paragraph_texts(node)
    node.xpath(".//w:p", "w" => WORD_NS).map { |paragraph| plain_paragraph_text(paragraph) }
  end

  def import_body(document, comments:, footnotes:)
    body = document.at_xpath("//w:body", "w" => WORD_NS)
    return [] unless body

    chapters = []
    current = nil
    saw_heading = false

    body.element_children.each do |node|
      case node.name
      when "p"
        parsed = parse_paragraph(node, comments:, footnotes:)
        if heading_paragraph?(node) && parsed.fetch(:text).strip.present?
          saw_heading = true
          current = blank_chapter(parsed.fetch(:text).strip)
          chapters << current
          next
        end

        current ||= blank_chapter("Chapter 1")
        chapters << current unless chapters.include?(current)
        append_block(current, parsed)
      when "tbl"
        current ||= blank_chapter("Chapter 1")
        chapters << current unless chapters.include?(current)
        table_blocks(node, comments:, footnotes:).each { |block| append_block(current, block) }
      end
    end

    if !saw_heading && chapters.length == 1
      chapters.first["title"] = "Chapter 1"
    end

    chapters.each do |chapter|
      chapter["text"] = chapter["text"].sub(/\n+\z/, "")
    end
    chapters
  end

  def blank_chapter(title)
    {
      "id" => "chapter-#{SecureRandom.uuid}",
      "title" => title,
      "text" => "",
      "annotations" => []
    }
  end

  def append_block(chapter, block)
    text = block.fetch(:text)
    return if text.empty? && block.fetch(:annotations).empty?

    separator = chapter["text"].empty? ? "" : "\n"
    base = chapter["text"].length + separator.length
    chapter["text"] << separator << text

    block.fetch(:annotations).each do |annotation|
      chapter["annotations"] << annotation.merge(
        "id" => annotation["id"].presence || "annotation-#{SecureRandom.uuid}",
        "start" => base + annotation.fetch("start"),
        "end" => base + annotation.fetch("end")
      )
    end
  end

  def table_blocks(table, comments:, footnotes:)
    table.xpath("./w:tr", "w" => WORD_NS).map do |row|
      cells = row.xpath("./w:tc", "w" => WORD_NS).map do |cell|
        paragraphs = cell.xpath("./w:p", "w" => WORD_NS).map do |paragraph|
          parse_paragraph(paragraph, comments:, footnotes:)
        end
        combine_blocks(paragraphs, " ")
      end
      combine_blocks(cells, "\t")
    end
  end

  def combine_blocks(blocks, separator)
    text = +""
    annotations = []

    blocks.each do |block|
      prefix = text.empty? ? "" : separator
      base = text.length + prefix.length
      text << prefix << block.fetch(:text)
      block.fetch(:annotations).each do |annotation|
        annotations << annotation.merge(
          "start" => base + annotation.fetch("start"),
          "end" => base + annotation.fetch("end")
        )
      end
    end

    { text:, annotations: }
  end

  def heading_paragraph?(paragraph)
    style = paragraph.at_xpath("./w:pPr/w:pStyle", "w" => WORD_NS)
    value = style && (style["w:val"] || style.attribute_with_ns("val", WORD_NS)&.value)
    value.to_s.match?(/\A(?:Heading|heading)[ _-]*[1-9]\z/) || value.to_s.match?(/\A[1-9]\z/)
  end

  def plain_paragraph_text(paragraph)
    parse_paragraph(paragraph, comments: {}, footnotes: {}).fetch(:text)
  end

  def parse_paragraph(paragraph, comments:, footnotes:)
    buffer = +""
    annotations = []
    open_comments = {}

    nodes = paragraph.xpath(
      ".//w:commentRangeStart | .//w:commentRangeEnd | .//w:footnoteReference | .//w:tab | .//w:br | .//w:cr | .//w:t",
      "w" => WORD_NS
    )
    nodes.each do |node|
      case node.name
      when "commentRangeStart"
        id = word_attr(node, "id")
        open_comments[id] = buffer.length
      when "commentRangeEnd"
        id = word_attr(node, "id")
        start = open_comments.delete(id) || buffer.length
        note = comments[id].to_s
        annotations << note_annotation("comment", start, buffer.length, note) if note.present?
      when "footnoteReference"
        id = word_attr(node, "id")
        note = footnotes[id].to_s
        annotations << note_annotation("footnote", buffer.length, buffer.length, note) if note.present?
      when "tab"
        buffer << "\t"
      when "br", "cr"
        buffer << "\n"
      when "t"
        buffer << node.text
      end
    end

    open_comments.each do |id, start|
      note = comments[id].to_s
      annotations << note_annotation("comment", start, buffer.length, note) if note.present?
    end

    { text: buffer, annotations: annotations }
  end

  def note_annotation(kind, start, finish, note)
    {
      "id" => "annotation-#{SecureRandom.uuid}",
      "kind" => kind,
      "start" => start,
      "end" => finish,
      "note" => note
    }
  end

  def word_attr(node, name)
    node["w:#{name}"] || node.attribute_with_ns(name, WORD_NS)&.value.to_s
  end
end
