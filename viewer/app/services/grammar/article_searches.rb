# frozen_string_literal: true

module Grammar
  class ArticleSearches
    def self.for(entry:, article_metadata:)
      configured = (
        entry.corpus_searches +
        Array(article_metadata["corpus_searches"]).select { |value| value.is_a?(Hash) }
      ).uniq
      return configured if configured.any?
      return [] unless entry.single_character?

      [{ "mode" => "exact", "term_a" => entry.headword }]
    end
  end
end
