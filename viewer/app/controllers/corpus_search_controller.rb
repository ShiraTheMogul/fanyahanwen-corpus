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
    source_prepared = source_prepared_search
    if source_prepared_requested? && source_prepared.nil?
      redirect_to corpus_search_path, alert: I18n.t("corpus_search.errors.prepared_not_found")
      return
    end

    query = source_prepared ? source_prepared.query : CorpusSearch::Query.from_params(params)
    comparison = CorpusSearch::ComparisonDefinition.from_params(params)

    unless query.valid?
      redirect_to query.relative_url, alert: query.errors.join(" ")
      return
    end

    if source_prepared
      unless source_prepared.frozen?
        redirect_to prepared_search_url(source_prepared), alert: I18n.t("corpus_search.comparison.errors.source_incomplete")
        return
      end

      comparison_errors = comparison.errors + comparison_option_errors(source_prepared, comparison)
      if comparison_errors.any?
        redirect_to prepared_search_url(source_prepared, anchor: "comparison"), alert: comparison_errors.join(" ")
        return
      end
    elsif comparison.requested? && !comparison.valid?
      redirect_to query.relative_url, alert: comparison.errors.join(" ")
      return
    end

    prepared = CorpusSearch::PreparedSearch.create!(
      query: query,
      locale: I18n.locale,
      comparison: comparison,
      source_prepared: source_prepared
    )
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
    @frozen_result_url = "#{request.base_url}#{prepared_search_url(@prepared_search)}"
    @analysis_metric = analysis_metric
    @analysis_report = if @prepared_search.complete?
      CorpusSearch::AnalysisReport.load(@prepared_search.output_dir.join("analysis", "standard"))
    end
    @comparison = @prepared_search.comparison
    @frozen_record = @prepared_search.frozen_record
    @methods_text = read_prepared_output(@prepared_search, "METHODS.txt")
    @citation_text = read_prepared_output(@prepared_search, "CITATION.txt")
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

  def source_prepared_search
    id = params[:source_prepared_id].to_s
    key = params[:source_prepared_key].to_s
    return nil unless source_prepared_requested?
    return nil if id.blank? || key.blank?

    CorpusSearch::PreparedSearch.find(id: id, key: key)
  end

  def source_prepared_requested?
    params[:source_prepared_id].present? || params[:source_prepared_key].present?
  end

  def comparison_option_errors(prepared, comparison)
    return [] unless comparison.valid?

    report = CorpusSearch::AnalysisReport.load(prepared.output_dir.join("analysis", "standard"))
    return [I18n.t("corpus_search.comparison.errors.analysis_unavailable")] unless report

    options = report.comparison_options(comparison.dimension)
    errors = []
    errors << I18n.t("corpus_search.comparison.errors.group_missing", group: comparison.left_group) unless options.include?(comparison.left_group)
    errors << I18n.t("corpus_search.comparison.errors.group_missing", group: comparison.right_group) unless options.include?(comparison.right_group)
    errors
  end

  def read_prepared_output(prepared, filename)
    path = prepared.output_dir.join(filename)
    path.file? ? path.read(encoding: "UTF-8") : nil
  rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
    path.binread.force_encoding(Encoding::UTF_8).scrub
  end

  def prepared_search_url(prepared, anchor: nil)
    path = "/corpus/search/prepared/#{prepared.id}?key=#{ERB::Util.url_encode(prepared.key)}"
    anchor ? "#{path}##{anchor}" : path
  end

  def analysis_metric
    candidate = params[:metric].to_s
    CorpusSearch::AnalysisReport::METRICS.include?(candidate) ? candidate : DEFAULT_ANALYSIS_METRIC
  end

  def live_query_url(query)
    "#{request.base_url}#{query.relative_url(include_presentation: false)}"
  end
end
