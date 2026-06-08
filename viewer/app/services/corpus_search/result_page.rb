# frozen_string_literal: true

module CorpusSearch
  class ResultPage
    attr_reader :query, :hits, :page, :per_page, :total, :complete, :truncated,
                :scanned_files, :candidate_files

    def initialize(query:, hits:, page:, per_page:, total:, complete:, truncated:,
                   scanned_files:, candidate_files:)
      @query = query
      @hits = hits
      @page = page
      @per_page = per_page
      @total = total
      @complete = complete
      @truncated = truncated
      @scanned_files = scanned_files
      @candidate_files = candidate_files
    end

    def total_pages
      return 1 if total.zero?

      (total.to_f / per_page).ceil
    end

    def previous_page
      page > 1 ? page - 1 : nil
    end

    def next_page
      return nil if page >= total_pages

      page + 1
    end
  end
end
