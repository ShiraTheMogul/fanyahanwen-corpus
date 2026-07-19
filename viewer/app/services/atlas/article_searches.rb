# frozen_string_literal: true

module Atlas
  class ArticleSearches
    def self.for(entry:, article_metadata:)
      configured = Array(article_metadata["corpus_searches"]).filter_map do |value|
        value.is_a?(Hash) ? Grammar::CorpusSearchDefinition.normalize(value) : nil
      end
      return configured if configured.any?
      return [] if entry.hanzi.blank?

      [{ "mode" => "exact", "term_a" => entry.hanzi, "context" => 30 }]
    end
  end
end
