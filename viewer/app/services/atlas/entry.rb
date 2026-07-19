# frozen_string_literal: true

require "pathname"

module Atlas
  class Entry
    attr_reader :attributes, :metadata_path

    def initialize(attributes, metadata_path: nil)
      @attributes = Grammar::MarkdownDocument.stringify_keys(attributes.to_h)
      @metadata_path = metadata_path && Pathname.new(metadata_path)
    end

    def id = attributes.fetch("id")
    def kind = attributes["kind"].presence || "state"

    def name
      value = attributes["name"]
      value.is_a?(Hash) ? Grammar::MarkdownDocument.stringify_keys(value) : {}
    end

    def title = name["display"].presence || hanzi.presence || id
    def hanzi = name["hanzi"].to_s
    def aliases = Array(name["alt"]).map(&:to_s).reject(&:blank?).uniq
    def article_path = attributes.fetch("article_path")
    def related_ids = Array(attributes["related"]).map(&:to_s).reject(&:blank?).uniq

    def timespan
      value = attributes["timespan"]
      value.is_a?(Hash) ? Grammar::MarkdownDocument.stringify_keys(value) : {}
    end

    def locations
      value = attributes["locations"]
      value.is_a?(Hash) ? Grammar::MarkdownDocument.stringify_keys(value) : {}
    end

    def capitals = Array(locations["capital"]).map(&:to_s).reject(&:blank?)
    def territory_note = locations["territory_note"].to_s
    def notable_authors = Array(attributes["notable_authors"]).map(&:to_s).reject(&:blank?)
    def notable_works = Array(attributes["notable_works"]).map(&:to_s).reject(&:blank?)
    def notes = attributes["notes"].to_s

    def search_label
      hanzi.present? && hanzi != title ? "#{title} (#{hanzi})" : title
    end
  end
end
