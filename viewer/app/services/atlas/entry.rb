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
    def kind = attributes["kind"].presence || "polity"

    def name
      value = attributes["name"]
      value.is_a?(Hash) ? Grammar::MarkdownDocument.stringify_keys(value) : {}
    end

    def title = name["display"].presence || hanzi.presence || id
    def hanzi = name["hanzi"].to_s
    def aliases = Array(name["alt"]).map(&:to_s).reject(&:blank?).uniq
    def article_path = attributes.fetch("article_path")
    def published_in_catalogue? = attributes["published"] == true
    def related_ids = Array(attributes["related"]).map(&:to_s).reject(&:blank?).uniq

    def timespan
      value = attributes["timespan"]
      value.is_a?(Hash) ? Grammar::MarkdownDocument.stringify_keys(value) : {}
    end

    def locations
      value = attributes["locations"]
      value.is_a?(Hash) ? Grammar::MarkdownDocument.stringify_keys(value) : {}
    end

    def corpus
      value = attributes["corpus"]
      value.is_a?(Hash) ? Grammar::MarkdownDocument.stringify_keys(value) : {}
    end

    def historical
      value = attributes["historical"]
      value.is_a?(Hash) ? Grammar::MarkdownDocument.stringify_keys(value) : {}
    end

    def atlas
      value = attributes["atlas"]
      value.is_a?(Hash) ? Grammar::MarkdownDocument.stringify_keys(value) : {}
    end

    def corpus_stats
      value = atlas["corpus_stats"]
      value.is_a?(Hash) ? Grammar::MarkdownDocument.stringify_keys(value) : {}
    end

    def capitals = Array(locations["capital"]).map(&:to_s).reject(&:blank?)
    def territory_note = locations["territory_note"].to_s
    def rulers = Array(attributes["rulers"]).map(&:to_s).reject(&:blank?)
    def notable_authors = Array(attributes["notable_authors"]).map(&:to_s).reject(&:blank?)
    def notable_works = Array(attributes["notable_works"]).map(&:to_s).reject(&:blank?)
    def notes = attributes["notes"].to_s

    def corpus_root = corpus["root"].to_s
    def periods
      values = Array(atlas["periods"]).map(&:to_s).reject(&:blank?).uniq
      values.presence || Array(corpus["periods"]).map(&:to_s).reject(&:blank?).uniq
    end
    def polities
      values = Array(corpus["polities"]).map(&:to_s).reject(&:blank?)
      values.unshift(corpus["polity"].to_s) if corpus["polity"].to_s.present?
      values.uniq
    end
    def polity = polities.first.to_s
    def corpus_paths = Array(corpus["paths"]).map(&:to_s).reject(&:blank?).uniq
    def macro_regions = Array(atlas["macro_regions"]).map(&:to_s).reject(&:blank?).uniq
    def attested_in = Array(historical["attested_in"]).map(&:to_s).reject(&:blank?).uniq
    def relationship_with_shang = historical["relationship_with_shang"].to_s
    def period_description = historical["period_description"].to_s

    def document_count = corpus_stats["document_count"].to_i
    def work_count = corpus_stats["work_count"].to_i
    def searchable_characters = corpus_stats["searchable_characters"].to_i
    def represented_authors = Array(corpus_stats["represented_authors"]).select { |row| row.is_a?(Hash) }
    def represented_works = Array(corpus_stats["represented_works"]).select { |row| row.is_a?(Hash) }

    def search_label
      hanzi.present? && hanzi != title ? "#{title} (#{hanzi})" : title
    end
  end
end
