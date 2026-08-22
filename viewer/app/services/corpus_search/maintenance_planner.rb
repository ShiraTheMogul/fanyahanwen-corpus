# frozen_string_literal: true

require "digest"
require "open3"
require "pathname"
require "set"

module CorpusSearch
  # Cheap change detector for corpus-search maintenance.
  #
  # A successful maintenance run records the committed corpus tree plus the
  # exact set/stat fingerprint of dirty corpus paths. Subsequent runs can then
  # avoid walking hundreds of thousands of corpus files when neither the corpus
  # nor chronology/parser dependencies changed. Git remains only a change
  # detector: the manifest cache and corpus filesystem are still authoritative.
  class MaintenancePlanner
    VERSION = 3
    STATE_PATH = "maintenance-state-v3.json"
    TARGETED_FILE_LIMIT = [ENV.fetch("CORPUS_SEARCH_INCREMENTAL_FILE_LIMIT", "5000").to_i, 1].max
    GENERATED_CORPUS_PATHS = [".metadata_id_registry.csv"].freeze

    Plan = Data.define(
      :manifest_action,
      :manifest_paths,
      :changed_paths,
      :metadata_ids_needed,
      :directory_changed,
      :atlas_sources_changed,
      :reasons,
      :previous_state,
      :current_state
    ) do
      def manifest_changed? = manifest_action != :cached
      def targeted? = manifest_action == :targeted
      def full? = %i[full force].include?(manifest_action)
    end

    attr_reader :cache_store, :root, :repo_root

    def initialize(
      root: Rails.configuration.x.corpus_root,
      cache_store: CacheStore.new,
      repo_root: Rails.root.parent
    )
      @root = Pathname(root.to_s).expand_path
      @cache_store = cache_store
      @repo_root = Pathname(repo_root.to_s).expand_path
      @corpus_relative = relative_to_repo(@root)
    end

    def plan(force: false)
      previous = read_state

      # The first incremental run, a stale manifest cache, and FORCE=1 already
      # imply a complete pass. Do not run Git's working-tree/untracked scan just
      # to rediscover an answer we already know. This matters enormously on a
      # large corpus under /mnt/c or another high-latency filesystem.
      if force
        return conservative_full_plan(
          previous: previous,
          action: :force,
          reason: "FORCE=1 requested a complete rebuild"
        )
      end

      # A missing/stale baseline already forces one safe pass, so check it
      # *before* touching the potentially huge compressed manifest. The v2
      # planner did this in the opposite order and spent ~10-15 seconds merely
      # inflating the old cache in PLAN mode on /mnt/c.
      if previous.blank? || previous["version"].to_i != VERSION
        return conservative_full_plan(
          previous: previous,
          action: :full,
          reason: "incremental maintenance baseline is missing or stale"
        )
      end

      unless manifest_cache_current?(previous)
        return conservative_full_plan(
          previous: previous,
          action: :full,
          reason: "manifest cache is missing or changed since the last successful maintenance run"
        )
      end

      current = current_state
      changed_paths = changed_paths_since(previous, current)
      manifest_paths = changed_paths.select { |path| manifest_relevant_path?(path) }
      reasons = []

      action = if previous["manifest_code_fingerprint"].to_s != current["manifest_code_fingerprint"].to_s
        reasons << "manifest/metadata dating code changed"
        :full
      elsif previous["authority_fingerprint"].to_s != current["authority_fingerprint"].to_s
        reasons << "historical chronology authority changed"
        :full
      elsif manifest_paths.empty?
        reasons << "no corpus text or metadata changes detected"
        :cached
      elsif manifest_paths.all? { |path| path.downcase.end_with?(".txt") } && manifest_paths.length <= TARGETED_FILE_LIMIT
        reasons << "#{manifest_paths.length} changed text file(s) can be refreshed directly"
        :targeted
      else
        reasons << "metadata/new-directory changes or too many paths changed for a safe targeted refresh"
        :full
      end

      Plan.new(
        manifest_action: action,
        manifest_paths: manifest_paths.freeze,
        changed_paths: changed_paths.freeze,
        metadata_ids_needed: metadata_ids_needed?(changed_paths, force: false),
        directory_changed: directory_changed?(changed_paths),
        atlas_sources_changed: previous["atlas_source_fingerprint"].to_s != current["atlas_source_fingerprint"].to_s,
        reasons: reasons.freeze,
        previous_state: previous.freeze,
        current_state: current.freeze
      )
    end

    def record_success!(manifest:, warm_terms_digest:, directory_index: nil)
      state = current_state.merge(
        "version" => VERSION,
        "recorded_at_utc" => Time.now.utc.iso8601,
        "manifest_version" => Manifest::VERSION,
        "manifest_generated_at" => manifest.generated_at.to_s,
        "manifest_cache_stat" => manifest_cache_stat,
        "manifest_term_fingerprint" => manifest.term_index_fingerprint.to_s,
        "warm_terms_digest" => warm_terms_digest.to_s,
        "directory_index_generated_at" => directory_index&.generated_at.to_s
      )
      cache_store.write_json(STATE_PATH, state)
      state
    end

    def previous_warm_terms_digest
      read_state["warm_terms_digest"].to_s
    end

    def previous_manifest_term_fingerprint
      read_state["manifest_term_fingerprint"].to_s
    end

    private

    def read_state
      @read_state ||= cache_store.read_json(STATE_PATH).to_h
    rescue StandardError
      {}
    end

    def current_state(include_dirty: true)
      {
        "version" => VERSION,
        "git_available" => git_available?,
        "corpus_tree" => corpus_tree,
        "dirty_paths" => include_dirty ? dirty_paths : {},
        "manifest_version" => Manifest::VERSION,
        "manifest_code_fingerprint" => manifest_code_fingerprint,
        "authority_fingerprint" => authority_fingerprint,
        "atlas_source_fingerprint" => atlas_source_fingerprint
      }
    end

    def conservative_full_plan(previous:, action:, reason:)
      current = current_state(include_dirty: false)
      Plan.new(
        manifest_action: action,
        manifest_paths: [].freeze,
        changed_paths: [].freeze,
        metadata_ids_needed: true,
        directory_changed: true,
        atlas_sources_changed: true,
        reasons: [reason].freeze,
        previous_state: previous.freeze,
        current_state: current.freeze
      )
    end

    def manifest_cache_current?(previous)
      path = cache_store.absolute(Manifest::CACHE_PATH)
      return false unless path.file?
      return false unless previous["manifest_version"].to_i == Manifest::VERSION

      recorded = previous["manifest_cache_stat"].to_s
      recorded.present? && recorded == stat_fingerprint(path)
    rescue Errno::ENOENT, Errno::EACCES, Errno::EIO
      false
    end

    def manifest_cache_stat
      path = cache_store.absolute(Manifest::CACHE_PATH)
      path.file? ? stat_fingerprint(path) : "missing"
    rescue Errno::ENOENT, Errno::EACCES, Errno::EIO
      "missing"
    end

    def changed_paths_since(previous, current)
      return filesystem_fallback_paths if !current["git_available"]
      return current.fetch("dirty_paths", {}).keys.sort if previous.blank?

      paths = Set.new
      old_tree = previous["corpus_tree"].to_s
      new_tree = current["corpus_tree"].to_s
      if old_tree.present? && new_tree.present? && old_tree != new_tree
        git_diff_tree_paths(old_tree, new_tree).each { |path| paths << path }
      elsif old_tree != new_tree
        # A missing/invalid tree hash means Git cannot prove which corpus paths
        # changed. Force the conservative full-scan marker.
        paths << repo_corpus_path("metadata.json")
      end

      previous_dirty = previous.fetch("dirty_paths", {}).to_h
      current_dirty = current.fetch("dirty_paths", {}).to_h
      (previous_dirty.keys | current_dirty.keys).each do |path|
        paths << path if previous_dirty[path].to_s != current_dirty[path].to_s
      end

      # --untracked-files=normal intentionally collapses a wholly new directory
      # instead of enumerating every file under it. Keep a clean/ directory
      # marker "changed" on every plan until it is tracked, because edits inside
      # an untracked directory do not reliably change the directory mtime. A full
      # manifest pass is the safe response and is still vastly cheaper to *plan*
      # than `git status --untracked-files=all` over the whole corpus.
      current_dirty.each do |path, fingerprint|
        paths << path if fingerprint.to_s.start_with?("??:") && path.to_s.end_with?("/") && corpus_clean_path?(path)
      end

      paths.reject { |path| generated_corpus_path?(path) }.to_a.sort
    end

    def filesystem_fallback_paths
      # Without Git there is no cheap, reliable recursive modification detector.
      # A metadata marker deliberately chooses the safe full-manifest path.
      [repo_corpus_path("metadata.json")]
    end

    def git_available?
      @git_available ||= begin
        _out, _err, status = Open3.capture3("git", "rev-parse", "--is-inside-work-tree", chdir: repo_root.to_s)
        status.success?
      rescue Errno::ENOENT
        false
      end
    end

    def corpus_tree
      return "" unless git_available? && @corpus_relative.present?

      out, _err, status = Open3.capture3("git", "rev-parse", "HEAD:#{@corpus_relative}", chdir: repo_root.to_s)
      status.success? ? out.strip : ""
    end

    def dirty_paths
      return {} unless git_available? && @corpus_relative.present?

      out, _err, status = Open3.capture3(
        "git", "status", "--porcelain=v1", "-z", "--untracked-files=normal", "--no-renames", "--", @corpus_relative,
        chdir: repo_root.to_s
      )
      return {} unless status.success?

      parse_porcelain_paths(out).each_with_object({}) do |(path, status_code), memo|
        next if generated_corpus_path?(path)

        memo[path] = "#{status_code}:#{stat_fingerprint(repo_root.join(path))}"
      end
    end

    def parse_porcelain_paths(output)
      parts = output.to_s.split("\0")
      rows = []
      index = 0
      while index < parts.length
        entry = parts[index]
        index += 1
        next if entry.blank?

        if entry.length >= 4 && entry[2] == " "
          status_code = entry[0, 2]
          rows << [entry[3..], status_code]
          if status_code.match?(/[RC]/) && index < parts.length
            rows << [parts[index], status_code]
            index += 1
          end
        else
          rows << [entry, "??"]
        end
      end
      rows.reject { |path, _status| path.to_s.blank? }
    end

    def stat_fingerprint(path)
      stat = File.lstat(path)
      [stat.ftype, stat.size, stat.mtime.to_i, stat.mtime.nsec, stat.ctime.to_i, stat.ctime.nsec].join(":")
    rescue Errno::ENOENT
      "missing"
    end

    def git_diff_tree_paths(old_tree, new_tree)
      out, _err, status = Open3.capture3(
        "git", "diff", "--name-only", "-z", old_tree, new_tree,
        chdir: repo_root.to_s
      )
      return [repo_corpus_path("metadata.json")] unless status.success?

      out.split("\0").reject(&:blank?).map { |path| repo_corpus_path(path) }
    end

    def manifest_relevant_path?(repo_path)
      relative = corpus_relative_path(repo_path)
      return false if relative.blank?

      return true if relative.end_with?("/") && corpus_clean_path?(repo_path)

      relative.downcase.end_with?(".txt") || File.basename(relative).casecmp("metadata.json").zero?
    end

    def corpus_clean_path?(repo_path)
      relative = corpus_relative_path(repo_path).to_s.tr("\\", "/")
      relative.split("/").include?("clean")
    end

    def metadata_ids_needed?(changed_paths, force:)
      return true if force || read_state.blank?

      relevant = changed_paths.select { |path| manifest_relevant_path?(path) }
      return false if relevant.empty?
      return true if relevant.any? { |path| File.basename(corpus_relative_path(path)).casecmp("metadata.json").zero? }

      store = CorpusMetadataStore.new(root: root.to_s)
      relevant.any? do |path|
        relative = corpus_relative_path(path)
        absolute = root.join(relative)
        next true unless absolute.file?

        metadata = store.search_metadata_for_path(relative)
        metadata["work_id"].nil? || metadata["document_id"].nil?
      rescue StandardError
        true
      end
    end

    def directory_changed?(changed_paths)
      payload = cache_store.read_json(DirectoryIndex::CACHE_PATH)
      return true unless payload.is_a?(Hash) && payload["version"].to_i == DirectoryIndex::VERSION

      known = Array(payload["paths"]).to_set
      changed_paths.any? do |repo_path|
        relative = corpus_relative_path(repo_path)
        next false if relative.blank?

        ancestors_for(relative).any? do |directory|
          next false unless directory.split("/").include?("clean")

          exists = root.join(directory).directory?
          exists != known.include?(directory)
        end
      end
    rescue StandardError
      true
    end

    def ancestors_for(path)
      parts = File.dirname(path).tr("\\", "/").split("/").reject(&:blank?)
      (1..parts.length).map { |length| parts.first(length).join("/") }
    end

    def authority_fingerprint
      metadata = HistoricalAuthorityIndex.metadata.to_h
      Digest::SHA256.hexdigest(
        %w[version cbdb_sha256 historical_fingerprint equivalence_version source_sha256].map { |key| metadata[key].to_s }.join("\0")
      )
    rescue StandardError
      "authority-unavailable"
    end

    def manifest_code_fingerprint
      paths = [
        Manifest.instance_method(:refresh!).source_location&.first,
        CorpusMetadataStore.instance_method(:search_metadata_for_path).source_location&.first,
        defined?(HistoricalMetadataDating) && HistoricalMetadataDating.instance_method(:search_metadata_for_path).source_location&.first,
        defined?(ManifestHistoricalExtension) && ManifestHistoricalExtension.instance_method(:fingerprint_for).source_location&.first,
        defined?(ManifestIncrementalExtension) && ManifestIncrementalExtension.instance_method(:refresh_paths!).source_location&.first
      ].compact.uniq
      digest_paths(paths)
    rescue StandardError
      "manifest-code-unavailable"
    end

    def atlas_source_fingerprint
      paths = Dir.glob(Rails.root.join("content", "atlas", "**", "*").to_s).select { |path| File.file?(path) }.sort
      digest_paths(paths)
    rescue StandardError
      "atlas-source-unavailable"
    end

    def digest_paths(paths)
      digest = Digest::SHA256.new
      Array(paths).each do |path|
        next unless File.file?(path)

        stat = File.stat(path)
        digest << path.to_s << "\0" << stat.size.to_s << ":" << stat.mtime.to_f.to_s << "\n"
      end
      digest.hexdigest
    end

    def generated_corpus_path?(repo_path)
      relative = corpus_relative_path(repo_path)
      GENERATED_CORPUS_PATHS.include?(relative)
    end

    def corpus_relative_path(repo_path)
      prefix = "#{@corpus_relative}/"
      value = repo_path.to_s.tr("\\", "/")
      return "" unless value == @corpus_relative || value.start_with?(prefix)

      value.delete_prefix(prefix)
    end

    def repo_corpus_path(relative)
      [@corpus_relative, relative.to_s.sub(%r{\A/+}, "")].reject(&:blank?).join("/")
    end

    def relative_to_repo(path)
      path.relative_path_from(repo_root).to_s.tr("\\", "/")
    rescue ArgumentError
      ""
    end
  end
end
