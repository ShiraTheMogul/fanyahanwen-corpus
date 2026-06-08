# frozen_string_literal: true

module CorpusSearch
  # Small parser for the corpus file headers.
  #
  # Corpus files commonly begin with lines like:
  #   # TITLE: ...
  #   # AUTHOR: ...
  #
  # Search should not depend on CorpusViewerController internals, so this parser
  # lives in a reusable service namespace.
  class FrontMatter
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

    def self.split(raw)
      new(raw).split
    end

    def initialize(raw)
      @raw = raw.to_s
    end

    def split
      lines = @raw.lines
      meta_lines = []
      index = 0

      while index < lines.length && lines[index].start_with?("#")
        meta_lines << lines[index]
        index += 1
      end

      [parse(meta_lines), lines[index..].to_a.join]
    end

    private

    def parse(lines)
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
