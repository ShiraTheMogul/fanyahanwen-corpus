# frozen_string_literal: true

module Atlas
  class ArticleSearches
    def self.for(entry:, article_metadata:)
      configured = Array(article_metadata["corpus_searches"]).filter_map do |value|
        value.is_a?(Hash) ? Grammar::CorpusSearchDefinition.normalize(value) : nil
      end
      return configured if configured.any?

      terms = ([entry.hanzi] + entry.aliases + entry.polities).map(&:to_s).reject(&:blank?).uniq.first(10)
      return [] if terms.empty?

      broad = search_for(terms)
      broad["label"] = terms.length == 1 ? "Mentions of #{terms.first}" : "Mentions of #{terms.join('、')}"

      return [broad] if entry.corpus_paths.empty?

      scoped = search_for(terms)
      scoped["label"] = "Within the entry’s corpus folder"
      scoped["folders"] = entry.corpus_paths

      terms.all? { |term| term.each_char.count == 1 } ? [scoped, broad] : [broad, scoped]
    end

    def self.search_for(terms)
      base = { "context" => 30 }
      if terms.length == 1
        base.merge("mode" => "exact", "term_a" => terms.first)
      else
        base.merge("mode" => "alternatives", "terms" => terms)
      end
    end
    private_class_method :search_for
  end
end
