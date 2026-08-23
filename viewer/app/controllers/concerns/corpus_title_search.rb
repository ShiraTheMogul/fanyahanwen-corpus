# frozen_string_literal: true

# Adds a work-title search mode to the existing GET /corpus/search endpoint.
# Full-text search remains untouched unless the request contains title_q.
module CorpusTitleSearch
  TITLE_RESULT_LIMIT = 250

  def index
    return super unless params.key?(:title_q)

    @title_query = params[:title_q].to_s.strip
    @title_group_geography = params[:title_group].to_s != "none"
    @title_chronology = params[:title_order].to_s == "desc" ? "desc" : "asc"
    @title_results = []
    @title_groups = []

    if @title_query.present?
      title_index = CorpusSearch::TitleIndex.load
      @title_results = title_index.search(
        query: @title_query,
        group_geography: @title_group_geography,
        chronology: @title_chronology,
        limit: TITLE_RESULT_LIMIT
      )
      @title_groups = group_title_results(@title_results) if @title_group_geography
      @title_index_work_count = title_index.work_count
    end

    render "corpus_search/title_index"
  rescue CorpusSearch::TitleIndex::CacheMissing => e
    @title_search_error = e.message
    render "corpus_search/title_index", status: :service_unavailable
  end

  private

  def group_title_results(results)
    Array(results).group_by do |row|
      row["macro_region"].presence ||
        row["nation"].presence ||
        row["corpus_root"].presence ||
        I18n.t("corpus_search.title_search.unknown_geography", default: "Unspecified geography")
    end
  end
end
