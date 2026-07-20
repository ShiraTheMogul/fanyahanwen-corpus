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

    directory_index = CorpusSearch::DirectoryIndex.build!
    puts "Built full directory index: #{directory_index.paths.length} clean-corpus directories."

    atlas_catalogue = Atlas::CatalogueBuilder.build!(manifest: manifest, directory_index: directory_index)
    puts "Built atlas catalogue: #{atlas_catalogue.entry_count} polities across #{atlas_catalogue.macro_region_count} macro-regions and #{atlas_catalogue.period_count} typed periods/subperiods."

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

    directory_index = CorpusSearch::DirectoryIndex.load_or_build
    puts "Directory index available: #{directory_index.paths.length} clean-corpus directories."

    atlas_catalogue = Atlas::CatalogueBuilder.build!(manifest: manifest, directory_index: directory_index)
    puts "Built atlas catalogue: #{atlas_catalogue.entry_count} polities across #{atlas_catalogue.macro_region_count} macro-regions and #{atlas_catalogue.period_count} typed periods/subperiods."
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

    physically_empty = []
    zero_searchable = []
    skipped_directories = []
    skipped_files = []
    invalid_utf8_files = []
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
            puts "[corpus_search] empty-file audit: #{txt_seen} TXT files checked; "                  "#{physically_empty.length} empty; #{zero_searchable.length} zero-searchable; #{skipped_directories.length} directories skipped"
          end

          raw = File.binread(path).force_encoding(Encoding::UTF_8)
          unless raw.valid_encoding?
            invalid_utf8_files << path
            raw = raw.scrub
          end

          body = CorpusSearch::DocumentReader.parse(raw).body.to_s
          body = body.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "").delete("\uFEFF")
          if !body.match?(/\S/)
            physically_empty << path
          elsif CorpusSearch::NormalizedText.build(body, punctuation: "ignore").units.empty?
            zero_searchable << path
          end
        rescue Errno::ENOENT, Errno::EACCES, Errno::EIO => e
          skipped_files << [path, e]
          warn "[corpus_search] skipped file #{path}: #{e.class}: #{e.message}"
        end
      end
    end

    puts "Checked #{txt_seen} TXT files."
    puts "Found #{physically_empty.length} physically empty/header-only TXT files."
    physically_empty.each { |path| puts "EMPTY\t#{path.relative_path_from(root)}" }
    puts "Found #{zero_searchable.length} non-empty files with zero searchable characters."
    zero_searchable.each { |path| puts "REVIEW\t#{path.relative_path_from(root)}" }
    puts "Found #{invalid_utf8_files.length} TXT files with invalid UTF-8 bytes; they were scrubbed in memory for this audit."
    invalid_utf8_files.each { |path| puts "INVALID_UTF8\t#{path.relative_path_from(root)}" }

    if skipped_directories.any? || skipped_files.any?
      warn "[corpus_search] WARNING: audit was incomplete: "            "#{skipped_directories.length} directories and #{skipped_files.length} files were unreadable."
      warn "[corpus_search] Re-run the task after OneDrive/WSL access stabilises."
    end

    if apply
      removed = 0
      deletion_targets = physically_empty.dup
      if ENV["APPLY_ZERO_SEARCHABLE"].to_s == "1"
        deletion_targets.concat(zero_searchable)
        warn "[corpus_search] APPLY_ZERO_SEARCHABLE=1: deleting punctuation/markup-only review records too."
      end
      deletion_targets.each do |path|
        begin
          File.delete(path)
          removed += 1
        rescue Errno::ENOENT
          # A file disappearing between audit and deletion is already gone.
        rescue Errno::EACCES, Errno::EIO => e
          warn "[corpus_search] could not remove #{path}: #{e.class}: #{e.message}"
        end
      end
      puts "Removed #{removed} TXT files. Rebuild the manifest next."
    else
      puts "Dry run only. APPLY=1 removes only EMPTY rows; REVIEW rows require APPLY=1 APPLY_ZERO_SEARCHABLE=1 after inspection."
    end
  end

  desc "Audit unambiguous JSON geography repairs (APPLY=1 writes changes; BACKUP=1 keeps .bak copies)"
  task repair_metadata_geography: :environment do
    root = Rails.configuration.x.corpus_root.to_s
    script = Rails.root.join("script/corpus_metadata_repair_geography.rb")
    args = [RbConfig.ruby, script.to_s, "--root", root, "--output", Rails.root.join("tmp/corpus_metadata_geography_repair").to_s]
    args << "--apply" if ENV["APPLY"].to_s == "1"
    args << "--backup" if ENV["BACKUP"].to_s == "1"
    abort "Metadata geography repair failed" unless system(*args)
    puts "Review tmp/corpus_metadata_geography_repair/geography_repairs.csv before rebuilding the manifest."
  end

end

namespace :corpus_search do
  desc "Audit invalid UTF-8 corpus TXT files (APPLY=1 BACKUP=1 scrubs invalid bytes in place)"
  task audit_text_encoding: :environment do
    require "csv"
    require "fileutils"

    root = Pathname(Rails.configuration.x.corpus_root).realpath
    apply = ENV["APPLY"].to_s == "1"
    backup = ENV["BACKUP"].to_s == "1"
    abort "APPLY=1 requires BACKUP=1 because scrubbing malformed bytes is destructive." if apply && !backup

    output = Rails.root.join("tmp", "corpus_search_encoding_audit")
    FileUtils.mkdir_p(output)
    rows = []
    checked = 0
    stack = [root]
    retries = [ENV.fetch("READ_RETRIES", "3").to_i, 1].max

    read_children = lambda do |directory|
      attempts = 0
      begin
        attempts += 1
        Dir.children(directory)
      rescue Errno::ENOENT, Errno::EACCES, Errno::EIO => e
        if attempts < retries
          warn "[corpus_search] encoding audit retrying #{directory} after #{e.class} (#{attempts}/#{retries})"
          sleep(0.25 * attempts)
          retry
        end
        rows << ["skipped_directory", directory.relative_path_from(root).to_s, e.class.name, e.message, ""]
        []
      end
    end

    until stack.empty?
      directory = stack.pop
      read_children.call(directory).each do |name|
        path = directory.join(name)
        begin
          stat = File.lstat(path)
          next if stat.symlink?
          if stat.directory?
            stack << path
          elsif stat.file? && path.extname.downcase == ".txt"
            checked += 1
            raw = File.binread(path).force_encoding(Encoding::UTF_8)
            next if raw.valid_encoding?

            relative = path.relative_path_from(root).to_s.tr("\\", "/")
            replacement_character = [0xFFFD].pack("U")
            invalid_count = raw.scrub(replacement_character).count(replacement_character)
            action = apply ? "repaired" : "invalid_utf8"
            rows << [action, relative, "Encoding::InvalidByteSequenceError", "invalid UTF-8 bytes", invalid_count]

            if apply
              FileUtils.cp(path, "#{path}.invalid-utf8.bak")
              temp = Pathname("#{path}.utf8-tmp-#{Process.pid}-#{SecureRandom.hex(4)}")
              temp.binwrite(raw.scrub.encode(Encoding::UTF_8))
              File.rename(temp, path)
            end
          end
        rescue Errno::ENOENT, Errno::EACCES, Errno::EIO => e
          rows << ["skipped_file", path.relative_path_from(root).to_s, e.class.name, e.message, ""]
        ensure
          FileUtils.rm_f(temp) if defined?(temp) && temp
        end
      end
      puts "[corpus_search] encoding audit: #{checked} TXT files checked" if checked.positive? && (checked % 10_000).zero?
    end

    report = output.join("text_encoding_issues.csv")
    CSV.open(report, "w", write_headers: true, headers: %w[action path error_class message replacement_characters], encoding: "UTF-8") do |csv|
      rows.each { |row| csv << row }
    end
    invalid = rows.count { |row| %w[invalid_utf8 repaired].include?(row[0]) }
    skipped = rows.count { |row| row[0].start_with?("skipped_") }
    puts "Checked #{checked} TXT files; found #{invalid} invalid UTF-8 files; #{skipped} paths skipped."
    puts "Report: #{report}"
    puts(apply ? "Malformed files were scrubbed with .invalid-utf8.bak backups." : "Dry run only. APPLY=1 BACKUP=1 performs a lossy scrub with backups.")
  end
end
