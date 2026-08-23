# frozen_string_literal: true

# Historical date/era lookups use only the controlled, file-backed orthography
# registry. The base initializer constructs AuthorityNameExpander with its broad
# corpus registry, whose version calculation queries VariantMapping immediately,
# so this integration mirrors the small base initializer without calling super.
module HistoricalDateResolverStaticNames
  def initialize(store: HistoricalAuthorityStore.default)
    @store = store
    @expander = AuthorityNameExpander.new(registry: AuthorityHanVariantRegistry.instance)
    @era_candidate_cache = {}
    @ruler_candidate_cache = {}
  end
end
