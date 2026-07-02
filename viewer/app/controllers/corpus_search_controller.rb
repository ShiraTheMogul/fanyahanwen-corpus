# frozen_string_literal: true

class CorpusSearchController < ApplicationController
  helper CorpusTextHelper
  helper CorpusSearchHelper

  INTERACTIVE_LIMIT = 1_000
  DEFAULT_ANALYSIS_METRIC = "occurrences_per_million"

  def index
    @query = CorpusSearch::Query.from_params(params)
    @searched = @query.requested?
    @result_page = nil
    @live_query_url = live_query_url(@query) if @query.valid?
    @manifest = CorpusSearch::Manifest.load if @searched && @query.valid?
    @folder_tree = CorpusSearch::FolderTree.load(manifest: @manifest)

    return unless @searched

    if @query.valid?
      @result_page = CorpusSearch::Runner.new(query: @query, manifest: @manifest).page(max_hits: INTERACTIVE_LIMIT)
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
      redirect_to query.relative_url, alert: query.errors.join(" ")
      return
    end

    prepared = CorpusSearch::PreparedSearch.create!(query: query, locale: I18n.locale)
    CorpusSearchJob.perform_later(prepared.id)

    redirect_to prepared_search_url(prepared), notice: I18n.t("corpus_search.notices.queued")
  end

  def prepared
    @prepared_search = find_prepared_search
    unless @prepared_search
      render plain: I18n.t("corpus_search.errors.prepared_not_found"), status: :not_found
      return
    end

    @live_query_url = "#{request.base_url}#{@prepared_search.query.relative_url(include_presentation: false)}"
    @frozen_result_url = request.original_url
    @analysis_metric = analysis_metric
    @analysis_report = if @prepared_search.complete?
      CorpusSearch::AnalysisReport.load(@prepared_search.output_dir.join("analysis", "standard"))
    end
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


  def analysis_metric
    candidate = params[:metric].to_s
    CorpusSearch::AnalysisReport::METRICS.include?(candidate) ? candidate : DEFAULT_ANALYSIS_METRIC
  end

  def live_query_url(query)
    "#{request.base_url}#{query.relative_url(include_presentation: false)}"
  end
end
