# frozen_string_literal: true

class CorpusSearchController < ApplicationController
  helper CorpusTextHelper

  INTERACTIVE_LIMIT = 1_000

  def index
    @query = CorpusSearch::Query.from_params(params)
    @searched = params[:term_a].present?
    @result_page = nil

    return unless @searched

    if @query.valid?
      @result_page = CorpusSearch::Runner.new(query: @query).page(max_hits: INTERACTIVE_LIMIT)
    else
      @result_page = CorpusSearch::ResultPage.new(
        query: @query,
        hits: [],
        page: @query.page,
        per_page: @query.per_page,
        total: 0,
        complete: true,
        truncated: false,
        scanned_files: 0,
        candidate_files: 0
      )
    end
  rescue Errno::ENOENT, ArgumentError => e
    @search_error = I18n.t("corpus_search.errors.search_failed", message: e.message)
  end

  def prepare
    query = CorpusSearch::Query.from_params(params)

    unless query.valid?
      redirect_to "/corpus/search?#{request.query_parameters.merge(term_a: query.term_a, mode: query.mode).to_query}", alert: query.errors.join(" ")
      return
    end

    prepared = CorpusSearch::PreparedSearch.create!(query: query, locale: I18n.locale)
    CorpusSearchJob.perform_later(prepared.id)

    redirect_to prepared_search_url(prepared), notice: I18n.t("corpus_search.notices.queued")
  end

  def prepared
    @prepared_search = find_prepared_search
    render plain: I18n.t("corpus_search.errors.prepared_not_found"), status: :not_found unless @prepared_search
  end

  def download
    prepared_search = find_prepared_search
    unless prepared_search&.complete? && prepared_search.zip_path&.file?
      render plain: I18n.t("corpus_search.errors.download_not_ready"), status: :not_found
      return
    end

    send_file prepared_search.zip_path, filename: File.basename(prepared_search.zip_path), type: "application/zip"
  end

  private

  def find_prepared_search
    CorpusSearch::PreparedSearch.find(id: params[:id], key: params[:key])
  end

  def prepared_search_url(prepared)
    "/corpus/search/prepared/#{prepared.id}?key=#{ERB::Util.url_encode(prepared.key)}"
  end
end
