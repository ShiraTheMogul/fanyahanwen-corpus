# frozen_string_literal: true

require "json"
require "pathname"

module Atlas
  # Human-curated display order for macro-regions and periods.
  #
  # The corpus manifest supplies the actual data. This file only tells the atlas
  # how a human should encounter it: region first, then a chronological period
  # sequence. Unknown regions or periods are retained and appended rather than
  # silently discarded.
  class Periodisation
    ROOT = Rails.root.join("content", "atlas", "periodisation.json")

    def self.default
      @default ||= new
    end

    def self.reset!
      @default = nil
    end

    attr_reader :path

    def initialize(path: ROOT)
      @path = Pathname.new(path)
    end

    def macro_regions
      payload.fetch("macro_regions")
    end

    def macro_region(id)
      regions_by_id[id.to_s]
    end

    def macro_region_for_root(corpus_root)
      roots_to_regions[corpus_root.to_s]
    end

    # The manifest may contain a corpus collection name such as 中國漢文 in
    # its macro_region column. That is not a geographical macro-region: it is
    # the name of the Literary Chinese corpus root. Convert it through the
    # periodisation map while preserving the original corpus_root elsewhere.
    def normalise_macro_region(value, corpus_root: nil)
      candidate = value.to_s.strip
      mapped = roots_to_regions[candidate]
      return mapped if mapped.present?

      return candidate if candidate.present?

      macro_region_for_root(corpus_root)
    end

    def label_for(id)
      macro_region(id)&.fetch("label", nil).presence || id.to_s
    end

    def macro_region_order(id)
      macro_regions.index { |row| row["id"] == id.to_s } || macro_regions.length
    end

    def period_order(macro_region_id, period)
      periods = Array(macro_region(macro_region_id)&.fetch("periods", []))
      periods.index(period.to_s) || periods.length
    end

    private

    def payload
      @payload ||= begin
        raw = path.binread.force_encoding(Encoding::UTF_8)
        raise ArgumentError, "Atlas periodisation is not valid UTF-8" unless raw.valid_encoding?

        parsed = JSON.parse(raw)
        raise ArgumentError, "Atlas periodisation must be a mapping" unless parsed.is_a?(Hash)
        raise ArgumentError, "Atlas macro_regions must be a list" unless parsed["macro_regions"].is_a?(Array)

        parsed["macro_regions"] = parsed["macro_regions"].map do |row|
          normalized = Grammar::MarkdownDocument.stringify_keys(row.to_h)
          normalized["id"] = normalized["id"].to_s
          normalized["label"] = normalized["label"].to_s.presence || normalized["id"]
          normalized["corpus_roots"] = Array(normalized["corpus_roots"]).map(&:to_s).reject(&:blank?).uniq
          normalized["periods"] = Array(normalized["periods"]).map(&:to_s).reject(&:blank?).uniq
          normalized
        end

        Atlas::UnicodeGuard.validate!(parsed, context: "atlas periodisation")
        parsed.freeze
      end
    rescue JSON::ParserError => e
      raise ArgumentError, "Invalid atlas periodisation JSON: #{e.message}"
    end

    def regions_by_id
      @regions_by_id ||= macro_regions.index_by { |row| row.fetch("id") }
    end

    def roots_to_regions
      @roots_to_regions ||= macro_regions.each_with_object({}) do |row, index|
        Array(row["corpus_roots"]).each { |root| index[root] = row.fetch("id") }
      end
    end
  end
end
