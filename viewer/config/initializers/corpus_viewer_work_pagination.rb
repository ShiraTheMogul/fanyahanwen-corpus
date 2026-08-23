# frozen_string_literal: true

Rails.application.config.to_prepare do
  CorpusViewerController.prepend(CorpusViewerWorkPagination) unless CorpusViewerController < CorpusViewerWorkPagination
end
