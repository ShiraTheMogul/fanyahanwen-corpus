# frozen_string_literal: true

namespace :corpus_search do
  desc "Rebuild the file manifest, current single-character term indexes, and corpus activity snapshots"
  task rebuild_manifest: :environment do
    manifest = CorpusSearch::Manifest.load(refresh: true, force: true)
    puts "Indexed #{manifest.documents.length} corpus text files."

    corpus_index = CorpusSearch::CorpusIndex.build!(manifest: manifest)
    puts "Built corpus index: #{corpus_index.document_count} searchable documents, #{corpus_index.work_count} works, #{corpus_index.folder_tree.roots.length} corpus roots."

    term_limit = Integer(ENV.fetch("CORPUS_SEARCH_MANIFEST_TERM_LIMIT", CorpusSearch::WarmTermList::DEFAULT_LIMIT.to_s))
    cache_store = CorpusSearch::CacheStore.new
    grammar_store = Grammar::EntryStore.default
    terms = CorpusSearch::WarmTermList.load(
      limit: term_limit,
      cache_store: cache_store,
      grammar_store: grammar_store
    )
    progress_every = Integer(ENV.fetch("CORPUS_SEARCH_WARM_PROGRESS_EVERY", "1_000"))

    puts "Refreshing #{terms.length} single-character term indexes from the rebuilt manifest."
    warmed = CorpusSearch::TermIndex.refresh_single_character_terms!(
      terms: terms,
      manifest: manifest,
      cache_store: cache_store,
      force: true,
      progress: lambda do |position, total, files_read, files_skipped, error = nil|
        if error
          puts "[corpus_search] term refresh skipped #{position}/#{total}: #{error.class}: #{error.message}"
        elsif progress_every.positive? && (position % progress_every).zero?
          puts "[corpus_search] term refresh: #{position}/#{total} documents; #{files_read} read; #{files_skipped} skipped"
        end
      end
    )
    puts "Refreshed #{warmed} single-character term indexes."

    frequencies = CorpusSearch::FrequencySnapshot.build!(
      terms: terms,
      manifest: manifest,
      cache_store: cache_store
    )
    puts "Built aggregate frequency snapshot for #{frequencies.fetch("counts", {}).length} characters."

    activity = CorpusActivity::SnapshotBuilder.new(manifest: manifest).build!
    puts "Built corpus activity feeds: #{activity.dig("feeds", "latest_texts", "total")} text folders and #{activity.dig("feeds", "recent_changes", "total")} changed files."
  end

  desc "Rebuild the cached corpus index from the existing manifest"
  task rebuild_corpus_index: :environment do
    manifest = CorpusSearch::Manifest.load
    corpus_index = CorpusSearch::CorpusIndex.build!(manifest: manifest)
    puts "Built corpus index: #{corpus_index.document_count} searchable documents, #{corpus_index.work_count} works, #{corpus_index.folder_tree.roots.length} corpus roots."
  end

  desc "Warm ranked, Grammar Wiki, and existing single-character term indexes"
  task warm_frequency_terms: :environment do
    limit = Integer(ENV.fetch("LIMIT", CorpusSearch::WarmTermList::DEFAULT_LIMIT.to_s))
    progress_every = Integer(ENV.fetch("CORPUS_SEARCH_WARM_PROGRESS_EVERY", "1_000"))
    force = ENV["FORCE"].to_s == "1"
    cache_store = CorpusSearch::CacheStore.new
    terms = CorpusSearch::WarmTermList.load(
      limit: limit,
      cache_store: cache_store,
      grammar_store: Grammar::EntryStore.default
    )

    abort "No single-character terms were found." if terms.empty?

    puts "Preparing to warm #{terms.length} single-character term indexes."
    puts "Use LIMIT=0 for the full ranked CSV only when the additional storage and runtime are intended."

    manifest = CorpusSearch::Manifest.load
    warmed = CorpusSearch::TermIndex.refresh_single_character_terms!(
      terms: terms,
      manifest: manifest,
      cache_store: cache_store,
      force: force,
      progress: lambda do |position, total, files_read, files_skipped, error = nil|
        if error
          puts "[corpus_search] warm skipped #{position}/#{total}: #{error.class}: #{error.message}"
        elsif progress_every.positive? && (position % progress_every).zero?
          puts "[corpus_search] warm progress: #{position}/#{total} documents; #{files_read} read; #{files_skipped} skipped"
        end
      end
    )

    frequencies = CorpusSearch::FrequencySnapshot.build!(
      terms: terms,
      manifest: manifest,
      cache_store: cache_store
    )

    puts "Warmed #{warmed} single-character term indexes."
    puts "Built aggregate frequency snapshot for #{frequencies.fetch("counts", {}).length} characters."
  end
end
