# frozen_string_literal: true

# Rails reload-safe integration points for authority-backed domain services.
# HTTP request dispatch stays in the controller which owns the route; keeping
# controller actions out of this prepend chain makes the active endpoint
# explicit and testable.
Rails.application.config.to_prepare do
  HistoricalAuthorityIndex.prepend(HistoricalAuthorityIndexStaticNames) unless HistoricalAuthorityIndex < HistoricalAuthorityIndexStaticNames
  # Materialized date/ca must sit inside HistoricalMetadataDating. HistoricalMetadataDating
  # calls super first; seeing baked numeric bounds there lets it skip the authority
  # resolver entirely for maintained metadata.
  CorpusMetadataStore.prepend(CorpusMetadataMaterializedDating) unless CorpusMetadataStore < CorpusMetadataMaterializedDating
  CorpusMetadataStore.prepend(HistoricalMetadataDating) unless CorpusMetadataStore < HistoricalMetadataDating
  CorpusSearch::Manifest.prepend(CorpusSearch::ManifestHistoricalExtension) unless CorpusSearch::Manifest < CorpusSearch::ManifestHistoricalExtension
  CorpusSearch::Manifest.prepend(CorpusSearch::ManifestIncrementalExtension) unless CorpusSearch::Manifest < CorpusSearch::ManifestIncrementalExtension
  HistoricalDateResolver.prepend(HistoricalDateResolverStaticNames) unless HistoricalDateResolver < HistoricalDateResolverStaticNames
  HistoricalDateResolver.prepend(CalendarEngineHistoricalDateResolver) unless HistoricalDateResolver < CalendarEngineHistoricalDateResolver
  CbdbAutoAnnotator.prepend(CbdbAutoAnnotatorStaticNames) unless CbdbAutoAnnotator < CbdbAutoAnnotatorStaticNames
  CbdbAutoAnnotator.prepend(CbdbAutoAnnotatorKindResolution) unless CbdbAutoAnnotator < CbdbAutoAnnotatorKindResolution
  CbdbAutoAnnotator.prepend(CbdbAutoAnnotatorStability) unless CbdbAutoAnnotator < CbdbAutoAnnotatorStability
  EraCalendarConverter.prepend(EraCalendarStaticNames) unless EraCalendarConverter < EraCalendarStaticNames
  ToolsController.prepend(EraCalendarTools) unless ToolsController < EraCalendarTools
end
