# frozen_string_literal: true

namespace :corpus_catalogue do
  desc "Rebuild the dedicated work/title timeline directly from corpus metadata.json files"
  task rebuild: :environment do
    authority_store = HistoricalAuthorityStore.default
    index = CorpusCatalogueIndex.build!(store: authority_store)
    puts "Built work catalogue: #{index.work_count} works at #{index.generated_at}."
  end
end
