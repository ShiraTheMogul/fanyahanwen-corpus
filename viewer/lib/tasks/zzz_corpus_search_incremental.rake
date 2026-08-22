# frozen_string_literal: true

require "digest"

# Replace the legacy always-force corpus_search:rebuild_manifest action after all
# ordinary task files have loaded. Preserve unknown prerequisites, but make the
# two expensive/known maintenance dependencies conditional inside the new task.
legacy_task = Rake::Task["corpus_search:rebuild_manifest"] if Rake::Task.task_defined?("corpus_search:rebuild_manifest")
legacy_prerequisites = Array(legacy_task&.prerequisites)
known_prerequisites = %w[environment authority:ensure_ready corpus_metadata_ids:repair]
preserved_prerequisites = legacy_prerequisites - known_prerequisites
legacy_task&.clear

namespace :corpus_search do
  desc "Incrementally refresh corpus-search caches (FORCE=1 performs the previous complete rebuild; PLAN=1 only prints the plan)"
  task rebuild_manifest: :environment do
    force = ENV["FORCE"].to_s == "1"
    plan_only = ENV["PLAN"].to_s == "1"

    preserved_prerequisites.each do |task_name|
      next unless Rake::Task.task_defined?(task_name)

      Rake::Task[task_name].invoke
    end

    if Rake::Task.task_defined?("authority:ensure_ready")
      Rake::Task["authority:ensure_ready"].invoke
    end

    puts "[corpus_search] Planning incremental maintenance#{plan_only ? ' (PLAN only)' : ''}..."
    planner = CorpusSearch::MaintenancePlanner.new
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    initial_plan = planner.plan(force: force)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    puts format("[corpus_search] Initial plan computed in %.2fs.", elapsed)

    if initial_plan.metadata_ids_needed && Rake::Task.task_defined?("corpus_metadata_ids:repair")
      if plan_only
        puts "[corpus_search] PLAN: metadata-ID reconciliation would run."
      else
        puts "[corpus_search] Corpus/metadata changes may affect IDs; running metadata-ID reconciliation."
        Rake::Task["corpus_metadata_ids:repair"].invoke
        Rake::Task["corpus_metadata_ids:repair"].reenable
      end
    else
      puts "[corpus_search] Metadata-ID reconciliation skipped: no new/missing-ID metadata change detected."
    end

    # In PLAN mode no ID repair is actually performed, so recomputing the exact
    # same plan only doubles the cost of Git/filesystem checks. A real run still
    # replans after repair because metadata.json may have been written.
    if plan_only
      plan = initial_plan
      puts "[corpus_search] Final plan reused from the initial PLAN pass (no writes occurred)."
    else
      planner = CorpusSearch::MaintenancePlanner.new
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      plan = planner.plan(force: force)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      puts format("[corpus_search] Final plan computed in %.2fs.", elapsed)
    end
    puts "[corpus_search] Maintenance plan: manifest=#{plan.manifest_action}; changed_paths=#{plan.changed_paths.length}; manifest_paths=#{plan.manifest_paths.length}; directory_index=#{plan.directory_changed ? 'rebuild' : 'reuse'}; atlas_sources=#{plan.atlas_sources_changed ? 'changed' : 'unchanged'}"
    plan.reasons.each { |reason| puts "[corpus_search]   - #{reason}" }

    if plan_only
      puts "[corpus_search] PLAN=1: no manifest/search caches were written."
      next
    end

    cache_store = CorpusSearch::CacheStore.new
    manifest = case plan.manifest_action
    when :force
      CorpusSearch::Manifest.load(refresh: true, force: true, cache_store: cache_store)
    when :full
      # Full filesystem walk, but unchanged TXT bodies are reused from the
      # existing manifest instead of being parsed again.
      CorpusSearch::Manifest.load(refresh: true, force: false, cache_store: cache_store)
    when :targeted
      CorpusSearch::Manifest.refresh_paths!(
        paths: plan.manifest_paths,
        cache_store: cache_store
      )
    else
      CorpusSearch::Manifest.load(cache_store: cache_store)
    end

    manifest_changed = plan.manifest_changed?

    corpus_index = begin
      existing = CorpusSearch::CorpusIndex.load(cache_store: cache_store)
      current = existing.manifest_generated_at.to_s == manifest.generated_at.to_s && !existing.empty?
      if force || manifest_changed || !current
        rebuilt = CorpusSearch::CorpusIndex.build!(manifest: manifest, cache_store: cache_store)
        puts "Built corpus index: #{rebuilt.document_count} searchable documents, #{rebuilt.work_count} works, #{rebuilt.folder_tree.roots.length} corpus roots."
        rebuilt
      else
        puts "[corpus_search] Corpus index is current; skipped rebuild."
        existing
      end
    rescue StandardError
      rebuilt = CorpusSearch::CorpusIndex.build!(manifest: manifest, cache_store: cache_store)
      puts "Built corpus index: #{rebuilt.document_count} searchable documents, #{rebuilt.work_count} works, #{rebuilt.folder_tree.roots.length} corpus roots."
      rebuilt
    end

    directory_index = if force || plan.directory_changed
      rebuilt = CorpusSearch::DirectoryIndex.build!
      puts "Built full directory index: #{rebuilt.paths.length} clean-corpus directories."
      rebuilt
    else
      begin
        existing = CorpusSearch::DirectoryIndex.load(cache_store: cache_store)
        puts "[corpus_search] Directory index is current; skipped filesystem traversal."
        existing
      rescue StandardError
        rebuilt = CorpusSearch::DirectoryIndex.build!
        puts "Built full directory index: #{rebuilt.paths.length} clean-corpus directories."
        rebuilt
      end
    end

    atlas_cache = cache_store.read_json(Atlas::Catalogue::CACHE_PATH) rescue nil
    atlas_current = atlas_cache.is_a?(Hash) && atlas_cache["version"].to_i == Atlas::Catalogue::VERSION
    if force || manifest_changed || plan.directory_changed || plan.atlas_sources_changed || !atlas_current
      atlas_catalogue = Atlas::CatalogueBuilder.build!(manifest: manifest, directory_index: directory_index, cache_store: cache_store)
      puts "Built atlas catalogue: #{atlas_catalogue.entry_count} polities across #{atlas_catalogue.macro_region_count} macro-regions and #{atlas_catalogue.period_count} typed periods/subperiods."
    else
      puts "[corpus_search] Atlas catalogue inputs are unchanged; skipped rebuild."
    end

    term_limit = Integer(ENV.fetch("CORPUS_SEARCH_MANIFEST_TERM_LIMIT", CorpusSearch::WarmTermList::DEFAULT_LIMIT.to_s))
    grammar_store = Grammar::EntryStore.default
    terms = CorpusSearch::WarmTermList.load(
      limit: term_limit,
      cache_store: cache_store,
      grammar_store: grammar_store
    )
    warm_terms_digest = Digest::SHA256.hexdigest(terms.join("\0"))
    previous_terms_digest = planner.previous_warm_terms_digest
    previous_term_manifest = planner.previous_manifest_term_fingerprint
    term_manifest_changed = previous_term_manifest.blank? || previous_term_manifest != manifest.term_index_fingerprint.to_s
    term_list_changed = previous_terms_digest.blank? || previous_terms_digest != warm_terms_digest
    warm_needed = force || term_manifest_changed || term_list_changed

    if warm_needed
      progress_every = Integer(ENV.fetch("CORPUS_SEARCH_WARM_PROGRESS_EVERY", "1_000"))
      puts "Refreshing #{terms.length} single-character term indexes#{force ? ' (forced)' : ''}."
      warmed = CorpusSearch::TermIndex.refresh_single_character_terms!(
        terms: terms,
        manifest: manifest,
        cache_store: cache_store,
        force: force,
        progress: lambda do |position, total, files_read, files_skipped, error = nil|
          if error
            puts "[corpus_search] term refresh skipped #{position}/#{total}: #{error.class}: #{error.message}"
          elsif progress_every.positive? && (position % progress_every).zero?
            puts "[corpus_search] term refresh: #{position}/#{total} documents; #{files_read} read; #{files_skipped} skipped"
          end
        end
      )
      puts "Refreshed #{warmed} single-character term indexes."

      frequencies = CorpusSearch::FrequencySnapshot.build!(terms: terms, manifest: manifest, cache_store: cache_store)
      puts "Built aggregate frequency snapshot for #{frequencies.fetch('counts', {}).length} characters."
    else
      puts "[corpus_search] Searchable bodies and warm-term list are unchanged; skipped term-index corpus pass and frequency rebuild."
    end

    activity_available = begin
      CorpusActivity::Snapshot.new(cache_store: cache_store).available?
    rescue StandardError
      false
    end
    if force || manifest_changed || !activity_available
      activity = CorpusActivity::SnapshotBuilder.new(manifest: manifest).build!
      puts "Built corpus activity feeds: #{activity.dig('feeds', 'latest_texts', 'total')} text folders and #{activity.dig('feeds', 'recent_changes', 'total')} changed files."
    else
      puts "[corpus_search] Manifest is unchanged; skipped corpus activity rebuild."
    end

    puts "[corpus_search] Recording incremental maintenance baseline (collapsed Git working-tree check)..."
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    planner.record_success!(
      manifest: manifest,
      warm_terms_digest: warm_terms_digest,
      directory_index: directory_index
    )
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    puts format("[corpus_search] Incremental maintenance baseline updated in %.2fs.", elapsed)
  end
end
