# frozen_string_literal: true

namespace :corpus_search do
  desc "Rebuild the file manifest for corpus search"
  task rebuild_manifest: :environment do
    manifest = CorpusSearch::Manifest.load(refresh: true, force: true)
    puts "Indexed #{manifest.documents.length} corpus text files."
  end

  desc "Warm term indexes from resources/fanyahanwen_research/LC_frequency_list_1224_ranked.csv"
  task warm_frequency_terms: :environment do
    require "csv"

    csv_path = Rails.root.join("resources", "fanyahanwen_research", "LC_frequency_list_1224_ranked.csv")
    abort "Missing #{csv_path}" unless csv_path.file?

    # Default to a starter cache. Set LIMIT=0 only when you really want every
    # single-character term from the CSV.
    limit = Integer(ENV.fetch("LIMIT", "200"))
    progress_every = Integer(ENV.fetch("CORPUS_SEARCH_WARM_PROGRESS_EVERY", "100"))

    terms = []
    CSV.foreach(csv_path, headers: true) do |row|
      term = row["character"] || row["char"] || row["Character"] || row[0]
      term = term.to_s.strip
      next if term.empty?
      next unless term.each_char.count == 1

      terms << term
      break if limit.positive? && terms.length >= limit
    end

    puts "Preparing to warm #{terms.length} single-character term indexes."
    puts "Use LIMIT=0 rails corpus_search:warm_frequency_terms for the full CSV later."

    manifest = CorpusSearch::Manifest.load
    warmed = CorpusSearch::TermIndex.refresh_single_character_terms!(
      terms: terms,
      manifest: manifest,
      progress: lambda do |position, total, files_read, files_skipped, error = nil|
        if error
          puts "[corpus_search] warm skipped file at #{position}/#{total}: #{error.class}: #{error.message}"
        elsif progress_every.positive? && (position % progress_every).zero?
          puts "[corpus_search] warm progress: #{position}/#{total} files checked; #{files_read} read; #{files_skipped} skipped"
        end
      end
    )

    puts "Warmed #{warmed} single-character term indexes."
  end
end
