# frozen_string_literal: true

class HomeController < ApplicationController
  def index
    @corpus_activity = CorpusActivity::Snapshot.new
    @corpus_activity_summary = @corpus_activity.summary
    load_title_search if params[:catalogue_q].present?
  end

  def activity
    @corpus_activity = CorpusActivity::Snapshot.new
    @corpus_activity_summary = @corpus_activity.summary
    @activity_feed = @corpus_activity.page(kind: params[:kind], number: params[:page])
    @activity_kind = @activity_feed["kind"]
  end

  private

  def load_title_search
    @catalogue_query = params[:catalogue_q].to_s.strip
    @catalogue_order = params[:catalogue_order].to_s == "desc" ? "desc" : "asc"
    @catalogue_geography = params[:catalogue_geography].to_s != "0"

    @catalogue_page = CorpusCatalogueIndex.load.timeline(
      query: @catalogue_query,
      order: @catalogue_order,
      geography: @catalogue_geography,
      page: params[:page]
    )
  rescue CorpusCatalogueIndex::CacheMissing => error
    @catalogue_error = error.message
  end
end
