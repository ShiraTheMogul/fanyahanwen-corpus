# frozen_string_literal: true

require "csv"

module CorpusSearch
  # Collects the single-character terms that should be rebuilt alongside the
  # corpus manifest. The list combines the ranked starter vocabulary, Grammar
  # Wiki headwords, and single-character indexes already created by searches.
  class WarmTermList
    DEFAULT_LIMIT = 200

    def self.load(limit: DEFAULT_LIMIT, cache_store: CacheStore.new, grammar_store: nil, csv_path: default_csv_path)
      (
        ranked_terms(limit: limit, csv_path: csv_path) +
        grammar_terms(grammar_store) +
        existing_index_terms(cache_store)
      ).select { |term| single_character?(term) }.uniq
    end

    def self.ranked_terms(limit: DEFAULT_LIMIT, csv_path: default_csv_path)
      path = Pathname.new(csv_path)
      return [] unless path.file?

      limit = Integer(limit)
      terms = []

      CSV.foreach(path, headers: true, encoding: "bom|utf-8") do |row|
        term = row["character"] || row["chars"] || row["char"] || row["Character"] || row[0]
        term = term.to_s.strip
        next unless single_character?(term)

        terms << term
        break if limit.positive? && terms.length >= limit
      end

      terms.uniq
    rescue ArgumentError, TypeError
      ranked_terms(limit: DEFAULT_LIMIT, csv_path: path)
    end

    def self.default_csv_path
      Rails.root.join("resources", "fanyahanwen_research", "LC_frequency_list_1224_ranked.csv")
    end

    def self.grammar_terms(grammar_store)
      return [] unless grammar_store

      grammar_store.all.select(&:single_character?).map(&:headword)
    end
    private_class_method :grammar_terms

    def self.existing_index_terms(cache_store)
      root = cache_store.root.join("term_indexes")
      return [] unless root.directory?

      root.glob("*.json.gz").filter_map do |path|
        relative = path.relative_path_from(cache_store.root).to_s
        payload = cache_store.read_json(relative)
        payload["term"].to_s if payload.is_a?(Hash)
      end
    rescue Errno::EACCES, Errno::EIO
      []
    end
    private_class_method :existing_index_terms

    def self.single_character?(term)
      term.to_s.each_char.count == 1
    end
    private_class_method :single_character?
  end
end
