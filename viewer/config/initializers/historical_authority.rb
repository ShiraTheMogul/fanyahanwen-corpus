# frozen_string_literal: true

# Rails reload-safe integration points. Keeping these as prepend modules means
# the authority layer can enrich existing metadata/annotation APIs without a
# parallel route or a duplicate corpus reader.
Rails.application.config.to_prepare do
  HistoricalAuthorityIndex.prepend(HistoricalAuthorityIndexStaticNames) unless HistoricalAuthorityIndex < HistoricalAuthorityIndexStaticNames
  CorpusMetadataStore.prepend(HistoricalMetadataDating) unless CorpusMetadataStore < HistoricalMetadataDating
  CorpusSearch::Manifest.prepend(CorpusSearch::ManifestHistoricalExtension) unless CorpusSearch::Manifest < CorpusSearch::ManifestHistoricalExtension
  CorpusSearch::Manifest.prepend(CorpusSearch::ManifestIncrementalExtension) unless CorpusSearch::Manifest < CorpusSearch::ManifestIncrementalExtension
  HistoricalDateResolver.prepend(HistoricalDateResolverStaticNames) unless HistoricalDateResolver < HistoricalDateResolverStaticNames
  CbdbAutoAnnotator.prepend(CbdbAutoAnnotatorStaticNames) unless CbdbAutoAnnotator < CbdbAutoAnnotatorStaticNames
  CbdbAutoAnnotator.prepend(CbdbAutoAnnotatorKindResolution) unless CbdbAutoAnnotator < CbdbAutoAnnotatorKindResolution
  CorpusAnnotationsController.prepend(HistoricalAutoAnnotations) unless CorpusAnnotationsController < HistoricalAutoAnnotations
  EraCalendarConverter.prepend(EraCalendarStaticNames) unless EraCalendarConverter < EraCalendarStaticNames
  ToolsController.prepend(EraCalendarTools) unless ToolsController < EraCalendarTools
end
