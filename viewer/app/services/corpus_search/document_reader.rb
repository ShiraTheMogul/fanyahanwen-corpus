# frozen_string_literal: true

require "digest"

module CorpusSearch
  # Reads one corpus text and separates bibliographic headers from searchable
  # body text. Every full-text search component must use this class rather than
  # inventing its own front-matter rules.
  class DocumentReader
    LABEL_MAP = {
      "TITLE" => "title",
      "PAGE_TITLE" => "title",
      "WORK_TITLE" => "title",
      "WORK_BASE_TITLE" => "work",
      "AUTHOR" => "author",
      "DATE" => "date_text",
      "TIMES" => "period",
      "TIME" => "period",
      "NATION" => "nation",
      "REGION" => "region",
      "CATEGORY" => "category"
    }.freeze

    Result = Struct.new(:metadata, :body, :body_fingerprint, keyword_init: true) do
      def to_h
        {
          "metadata" => metadata,
          "body" => body,
          "body_fingerprint" => body_fingerprint
        }
      end
    end

    class << self
      def read(fs:, path:)
        raw = fs.read_text(fs.resolve(path))
        parse(raw)
      end

      def parse(raw)
        text = raw.to_s.delete_prefix("\uFEFF")
        metadata, body = split_text(text)

        Result.new(
          metadata: metadata,
          body: body,
          body_fingerprint: Digest::SHA256.hexdigest(body)
        )
      end

      def split(raw)
        result = parse(raw)
        [result.metadata, result.body]
      end

      private

      def split_text(text)
        lines = text.lines
        first_content = first_nonblank_line_index(lines)

        # A file with no initial metadata block is entirely searchable body text.
        return [{}, text] unless first_content && metadata_line?(lines[first_content])

        metadata_lines = []
        index = first_content

        while index < lines.length && metadata_line?(lines[index])
          metadata_lines << lines[index]
          index += 1
        end

        # Separator lines are formatting between the metadata block and body;
        # they are not part of either one.
        index += 1 while index < lines.length && blank_line?(lines[index])

        [parse_metadata(metadata_lines), lines[index..].to_a.join]
      end

      def first_nonblank_line_index(lines)
        lines.index { |line| !blank_line?(line) }
      end

      def metadata_line?(line)
        line.to_s.start_with?("#")
      end

      def blank_line?(line)
        line.to_s.match?(/\A[[:space:]]*\z/)
      end

      def parse_metadata(lines)
        lines.each_with_object({}) do |line, metadata|
          clean = line.sub(/\A#\s*/, "").strip
          next if clean.empty?

          key, value = if clean.include?(":")
            clean.split(":", 2).map(&:strip)
          else
            [clean, ""]
          end

          normalized = normalize_key(key)
          next if normalized.empty?

          metadata[normalized] = value.to_s
        end
      end

      def normalize_key(key)
        upcased = key.to_s.strip.upcase
        LABEL_MAP.fetch(upcased) { upcased.downcase }
      end
    end
  end
end
