# frozen_string_literal: true

namespace :corpus_search do
  desc "Rebuild the work-level title-search index from the cached corpus manifest"
  task rebuild_title_index: :environment do
    cache_store = CorpusSearch::CacheStore.new
    manifest = CorpusSearch::Manifest.new(
      root: Rails.configuration.x.corpus_root,
      cache_store: cache_store
    ).load_cached!
    index = CorpusSearch::TitleIndex.build!(manifest: manifest, cache_store: cache_store)
    puts "Built title index: #{index.work_count} works; manifest #{index.manifest_generated_at}; equivalence #{index.equivalence_version}."
  end
end

# Keep title search on the same maintenance lifecycle as the corpus manifest.
# This action runs after the existing incremental task and performs no corpus
# walk when the title cache is already current.
if Rake::Task.task_defined?("corpus_search:rebuild_manifest")
  Rake::Task["corpus_search:rebuild_manifest"].enhance do
    next if ENV["PLAN"].to_s == "1"

    cache_store = CorpusSearch::CacheStore.new
    corpus_index = CorpusSearch::CorpusIndex.load(cache_store: cache_store)
    title_index = begin
      CorpusSearch::TitleIndex.load(cache_store: cache_store)
    rescue CorpusSearch::TitleIndex::CacheMissing
      nil
    end

    if ENV["FORCE"].to_s == "1" ||
       title_index.nil? ||
       !title_index.current_for?(manifest_generated_at: corpus_index.manifest_generated_at)
      manifest = CorpusSearch::Manifest.new(
        root: Rails.configuration.x.corpus_root,
        cache_store: cache_store
      ).load_cached!
      rebuilt = CorpusSearch::TitleIndex.build!(manifest: manifest, cache_store: cache_store)
      puts "Built title index: #{rebuilt.work_count} works."
    else
      puts "[corpus_search] Work-title index is current; skipped rebuild."
    end
  end
end
