require "fileutils"
require "pathname"

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

  desc "Audit or remove empty corpus TXT files (APPLY=1 performs deletion; otherwise dry run)"
  task purge_empty_documents: :environment do
    root = Pathname(Rails.configuration.x.corpus_root).realpath
    apply = ENV["APPLY"].to_s == "1"
    retry_limit = [ENV.fetch("READ_RETRIES", "3").to_i, 1].max
    progress_every = [ENV.fetch("PROGRESS_EVERY", "10000").to_i, 1].max

    empty = []
    skipped_directories = []
    skipped_files = []
    directories = [root]
    txt_seen = 0

    read_children = lambda do |directory|
      attempts = 0

      begin
        attempts += 1
        Dir.children(directory)
      rescue Errno::ENOENT, Errno::EACCES, Errno::EIO => e
        if attempts < retry_limit
          warn "[corpus_search] retrying directory #{directory} after #{e.class} "                "(attempt #{attempts}/#{retry_limit})"
          sleep 0.25 * attempts
          retry
        end

        skipped_directories << [directory, e]
        warn "[corpus_search] skipped directory #{directory}: #{e.class}: #{e.message}"
        []
      end
    end

    until directories.empty?
      directory = directories.pop

      read_children.call(directory).each do |name|
        path = Pathname(directory).join(name)

        begin
          stat = File.lstat(path)

          # Do not follow directory symlinks: a corpus symlink loop would otherwise
          # make this maintenance task walk forever.
          if stat.directory? && !stat.symlink?
            directories << path
            next
          end

          next unless stat.file? && path.extname.downcase == ".txt"

          txt_seen += 1
          if (txt_seen % progress_every).zero?
            puts "[corpus_search] empty-file audit: #{txt_seen} TXT files checked; "                  "#{empty.length} empty; #{skipped_directories.length} directories skipped"
          end

          begin
            has_content = File.foreach(path, encoding: "UTF-8").any? do |line|
              line.delete("\uFEFF").match?(/\S/)
            end
          rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
            has_content = File.binread(path).match?(/\S/)
          end

          empty << path unless has_content
        rescue Errno::ENOENT, Errno::EACCES, Errno::EIO => e
          skipped_files << [path, e]
          warn "[corpus_search] skipped file #{path}: #{e.class}: #{e.message}"
        end
      end
    end

    puts "Checked #{txt_seen} TXT files."
    puts "Found #{empty.length} empty TXT files."
    empty.each { |path| puts path.relative_path_from(root) }

    if skipped_directories.any? || skipped_files.any?
      warn "[corpus_search] WARNING: audit was incomplete: "            "#{skipped_directories.length} directories and #{skipped_files.length} files were unreadable."
      warn "[corpus_search] Re-run the task after OneDrive/WSL access stabilises."
    end

    if apply
      removed = 0
      empty.each do |path|
        begin
          File.delete(path)
          removed += 1
        rescue Errno::ENOENT
          # A file disappearing between audit and deletion is already gone.
        rescue Errno::EACCES, Errno::EIO => e
          warn "[corpus_search] could not remove #{path}: #{e.class}: #{e.message}"
        end
      end
      puts "Removed #{removed} empty TXT files. Rebuild the manifest next."
    else
      puts "Dry run only. Re-run with APPLY=1 to remove the files listed above."
    end
  end

end
