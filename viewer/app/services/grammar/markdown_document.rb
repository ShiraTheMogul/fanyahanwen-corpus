# frozen_string_literal: true

require "date"
require "yaml"

module Grammar
  class MarkdownDocument
    PUBLICATION_KEYS = %w[
      contributors published_at updated_at licence license revision
      translation_of original_published_at
    ].freeze

    REFERENCE_HEADINGS = [
      "references",
      "reference",
      "bibliography",
      "works cited",
      "參考文獻",
      "參考書目",
      "徵引書目"
    ].freeze

    attr_reader :metadata, :body, :raw

    def self.parse(raw)
      new(raw)
    end

    def self.dump(metadata:, body:)
      cleaned = stringify_keys(metadata.to_h)
      yaml = YAML.dump(cleaned).sub(/\A---\s*\n/, "")
      "---\n#{yaml}---\n\n#{normalise_body(body)}"
    end

    def self.stringify_keys(hash)
      hash.each_with_object({}) do |(key, value), output|
        output[key.to_s] =
          case value
          when Hash
            stringify_keys(value)
          when Array
            value.map { |item| item.is_a?(Hash) ? stringify_keys(item) : item }
          else
            value
          end
      end
    end

    def self.normalise_body(value)
      text = value.to_s.dup.force_encoding("UTF-8").scrub
      text = text.sub(/\A\n+/, "")
      text.end_with?("\n") ? text : "#{text}\n"
    end

    def initialize(raw)
      @raw = raw.to_s.dup.force_encoding("UTF-8").scrub
      @metadata, @body = split(@raw)
    end

    def references_heading?
      body.each_line.any? do |line|
        match = line.match(/\A##\s+(.+?)\s*#*\s*\z/)
        next false unless match

        REFERENCE_HEADINGS.include?(normalise_heading(match[1]))
      end
    end

    def without_publication_metadata
      self.class.dump(
        metadata: metadata.reject { |key, _| PUBLICATION_KEYS.include?(key.to_s) },
        body: body
      )
    end

    private

    def split(text)
      return [{}, self.class.normalise_body(text)] unless text.start_with?("---\n", "---\r\n")

      lines = text.lines
      closing_index = lines.each_index.drop(1).find { |index| lines[index].strip == "---" }
      raise ArgumentError, "Unclosed YAML front matter" unless closing_index

      yaml_text = lines[1...closing_index].join
      parsed = YAML.safe_load(
        yaml_text,
        permitted_classes: [Date, Time],
        permitted_symbols: [],
        aliases: false
      )
      raise ArgumentError, "Grammar article front matter must be a key/value mapping" unless parsed.nil? || parsed.is_a?(Hash)

      [self.class.stringify_keys(parsed || {}), self.class.normalise_body(lines[(closing_index + 1)..].join)]
    end

    def normalise_heading(value)
      value.to_s.downcase.strip.gsub(/[：:]\z/, "")
    end
  end
end
