class HomeController < ApplicationController
  def index
    @corpus_activity = CorpusActivity::Snapshot.new
    @corpus_activity_summary = @corpus_activity.summary
  end

  def activity
    @corpus_activity = CorpusActivity::Snapshot.new
    @corpus_activity_summary = @corpus_activity.summary
    @activity_feed = @corpus_activity.page(kind: params[:kind], number: params[:page])
    @activity_kind = @activity_feed["kind"]
  end
end
