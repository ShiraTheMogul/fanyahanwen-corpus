# frozen_string_literal: true

class CorpusSearchController < ApplicationController
  helper CorpusTextHelper
  helper CorpusSearchHelper

  INTERACTIVE_LIMIT = 1_000
  DEFAULT_ANALYSIS_METRIC = "occurrences_per_million"
  DEFAULT_FULL_SEARCH_CONCURRENCY = 2

  def index
    @search_scope = search_scope
    @query = CorpusSearch::Query.from_params(params)
    @searched = @query.requested? && targeted_search?
    @result_page = nil
    @live_query_url = live_query_url(@query) if @query.valid?
    @manifest = CorpusSearch::Manifest.load_for_query(query: @query) if @searched && @query.valid?
    @folder_tree = CorpusSearch::FolderTree.load

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
  rescue Errno::ENOENT, ArgumentError, CorpusSearch::Manifest::CacheMissing => e
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

    full_search = full_search_request?
    client_identity = full_search ? CorpusSearch::ClientIdentity.from_request(request: request, cookies: cookies) : nil
    if full_search
      throttle_error = full_search_throttle_error(client_identity, notification_email: params[:notification_email])
      if throttle_error
        redirect_to "#{query.relative_url}&search_scope=full", alert: throttle_error
        return
      end
    end

    prepared = CorpusSearch::PreparedSearch.create!(
      query: query,
      locale: I18n.locale,
      comparison: comparison,
      source_prepared: source_prepared,
      full_search: full_search,
      client_identity: client_identity,
      notification_email: full_search ? params[:notification_email] : nil
    )
    CorpusSearchJob.perform_later(prepared.id)

    redirect_to prepared_search_url(prepared), notice: I18n.t("corpus_search.notices.queued")
  end

  def prepared
    @prepared_search = find_prepared_search
    unless @prepared_search
      respond_to do |format|
        format.json { render json: { error: I18n.t("corpus_search.errors.prepared_not_found") }, status: :not_found }
        format.html { render plain: I18n.t("corpus_search.errors.prepared_not_found"), status: :not_found }
      end
      return
    end

    if request.format.json?
      render json: prepared_status_payload(@prepared_search)
      return
    end

    @full_search_progress_seed = full_search_progress_seed(@prepared_search) if @prepared_search.full_search?
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

    prepared_search.mark_downloaded! if prepared_search.full_search?
    send_file prepared_search.zip_path, filename: File.basename(prepared_search.zip_path), type: "application/zip"
  end

  # Route intentionally not added by this patch. See ROUTES_TO_ADD_FOR_FULL_SEARCH.txt.
  def cancel
    prepared_search = find_prepared_search
    unless prepared_search
      render json: { error: I18n.t("corpus_search.errors.prepared_not_found") }, status: :not_found
      return
    end

    prepared_search.request_cancel!
    render json: prepared_status_payload(prepared_search)
  end

  private

  def search_scope
    params[:search_scope].to_s == "full" ? "full" : "targeted"
  end

  def targeted_search?
    @search_scope == "targeted"
  end

  def full_search?
    @search_scope == "full"
  end

  def full_search_request?
    params[:search_scope].to_s == "full" || params[:full_search].to_s == "1"
  end

  def full_search_throttle_error(client_identity, notification_email: nil)
    email_key = CorpusSearch::ClientIdentity.email_key(notification_email)
    if CorpusSearch::PreparedSearch.active_full_search_for_client?(client_identity, email_key: email_key)
      return I18n.t("corpus_search.errors.full_search_active")
    end

    if CorpusSearch::PreparedSearch.active_full_search_count >= full_search_concurrency_limit
      return I18n.t("corpus_search.errors.full_search_busy")
    end

    nil
  end

  def full_search_concurrency_limit
    Integer(ENV.fetch("CORPUS_SEARCH_FULL_SEARCH_CONCURRENCY", DEFAULT_FULL_SEARCH_CONCURRENCY.to_s))
  rescue ArgumentError, TypeError
    DEFAULT_FULL_SEARCH_CONCURRENCY
  end

  def prepared_status_payload(prepared_search)
    payload = prepared_search.payload
    progress = payload.fetch("progress", {})
    files_total = progress["files_total"].to_i
    files_scanned = progress["files_scanned"].to_i
    percent = files_total.positive? ? ((files_scanned.to_f / files_total) * 100).clamp(0, 100).round(1) : 0

    {
      id: prepared_search.id,
      key: prepared_search.key,
      status: prepared_search.status,
      status_label: I18n.t("corpus_search.statuses.#{prepared_search.status}", default: prepared_search.status.humanize),
      stage: progress["stage"].to_s,
      stage_label: I18n.t("corpus_search.stages.#{progress["stage"]}", default: progress["stage"].to_s.humanize),
      query: prepared_search.query.display_label,
      files_scanned: files_scanned,
      files_total: files_total,
      percent: percent,
      hits_found: progress["hits_found"].to_i,
      complete: prepared_search.complete?,
      cancelled: prepared_search.cancelled?,
      failed: prepared_search.failed?,
      full_search: prepared_search.full_search?,
      status_url: "/corpus/search/prepared/#{prepared_search.id}.json?key=#{ERB::Util.url_encode(prepared_search.key)}",
      cancel_url: "/corpus/search/prepared/#{prepared_search.id}/cancel?key=#{ERB::Util.url_encode(prepared_search.key)}",
      download_url: prepared_search.complete? ? "/corpus/search/prepared/#{prepared_search.id}/download?key=#{ERB::Util.url_encode(prepared_search.key)}" : nil
    }
  end

  def full_search_progress_seed(prepared_search)
    prepared_status_payload(prepared_search).slice(:id, :key, :query, :status_url, :cancel_url, :download_url)
  end

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
