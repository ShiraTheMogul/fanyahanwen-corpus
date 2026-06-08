# frozen_string_literal: true

class CorpusSearchJob < ApplicationJob
  queue_as :default

  def perform(prepared_search_id)
    prepared_search = CorpusSearch::PreparedSearch.find_internal(id: prepared_search_id)
    return unless prepared_search

    CorpusSearch::ExportWriter.new(prepared_search: prepared_search).write!
  end
end
