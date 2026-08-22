# frozen_string_literal: true

# Rails reload-safe integration points. Keeping these as prepend modules means
# the authority layer can enrich existing metadata/annotation APIs without a
# parallel route or a duplicate corpus reader.
Rails.application.config.to_prepare do
  CorpusMetadataStore.prepend(HistoricalMetadataDating) unless CorpusMetadataStore < HistoricalMetadataDating
  CorpusSearch::Manifest.prepend(CorpusSearch::ManifestHistoricalExtension) unless CorpusSearch::Manifest < CorpusSearch::ManifestHistoricalExtension
  CorpusSearch::Manifest.prepend(CorpusSearch::ManifestIncrementalExtension) unless CorpusSearch::Manifest < CorpusSearch::ManifestIncrementalExtension
  CorpusAnnotationsController.prepend(HistoricalAutoAnnotations) unless CorpusAnnotationsController < HistoricalAutoAnnotations
  ToolsController.prepend(EraCalendarTools) unless ToolsController < EraCalendarTools
end
