# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "pathname"
require "time"

module CorpusSearch
  # Rebuildable index of corpus files and their light metadata.
  #
  # Corpus .txt files are body text; per-work metadata.json files are the
  # metadata source of truth. This manifest records enough information to find
  # files safely, filter them, and notice changes.
  class Manifest
    DEFAULT_SKIP_DIRS = %w[.git .svn node_modules tmp log storage bak vendor].freeze
    VERSION = 8
    CACHE_PATH = "manifest.json.gz"
    FRONT_MATTER_READ_BYTES = 65_536

    class CacheMissing < StandardError; end
    class IncompleteScan < StandardError; end
    class InvalidUtf8Document < StandardError; end

    attr_reader :documents, :generated_at, :scan_issues

    def self.load(root: Rails.configuration.x.corpus_root, cache_store: CacheStore.new, refresh: false, force: false)
      manifest = new(root: root, cache_store: cache_store)
      if refresh || force
        manifest.refresh!(force: force)
      else
        manifest.load_cached_or_refresh!
      end
      manifest
    end

    def self.load_for_query(query:, root: Rails.configuration.x.corpus_root, cache_store: CacheStore.new, refresh: false)
      # A web request must never build any manifest, including a supposedly
      # "targeted" one. The administrator-built full manifest already contains
      # every document needed for folder filtering; Runner#candidate_documents
      # applies include/exclude folders in memory.
      #
      # This also avoids two serious failure modes seen on WSL/OneDrive:
      #   * selecting a large root folder synchronously walked hundreds of
      #     thousands of files and held the request open for tens of minutes;
      #   * concurrent requests attempted to write the same scoped cache file.
      #
      # `query` and `refresh` remain in the signature for compatibility with
      # callers, but refreshes belong to maintenance tasks, never page loads.
      new(root: root, cache_store: cache_store).load_cached!
    end


    def initialize(root:, cache_store: CacheStore.new)
      @root = File.realpath(root.to_s)
      @cache_store = cache_store
      @documents = []
      @documents_by_id = nil
      @progress_every = integer_env("CORPUS_SEARCH_PROGRESS_EVERY", 500)
      @dir_progress_every = integer_env("CORPUS_SEARCH_DIR_PROGRESS_EVERY", 1_000)
      @max_files = integer_env("CORPUS_SEARCH_MAX_FILES", 0)
      @debug_dirs = ENV["CORPUS_SEARCH_DEBUG_DIRS"].to_s == "1"
      @silent = ENV["CORPUS_SEARCH_SILENT"].to_s == "1"
      @read_retries = [integer_env("CORPUS_SEARCH_READ_RETRIES", 3), 1].max
      @scan_issues = []
      @metadata_store = CorpusMetadataStore.new(root: @root)
    end


    def load_cached!
      cached = @cache_store.read_json(CACHE_PATH, freeze: true)
      unless cache_current?(cached)
        raise CacheMissing, "The corpus search manifest has not been built. Run bin/rails corpus_search:rebuild_manifest as a maintenance command."
      end

      load_from_payload(cached)
      progress("manifest loaded from cache: #{@documents.length} documents")
      self
    end

    def load_cached_or_refresh!
      cached = @cache_store.read_json(CACHE_PATH, freeze: true)

      if cache_current?(cached)
        load_from_payload(cached)
        progress("manifest loaded from cache: #{@documents.length} documents")
        self
      else
        refresh!
      end
    end

    def refresh!(force: false)
      progress("manifest scan starting at #{@root}")
      cached = force ? nil : @cache_store.read_json(CACHE_PATH, freeze: true)
      cached_documents = cache_current?(cached) ? cached["documents"] : nil
      @scan_issues = []
      scanned = scan_documents(cached_documents: cached_documents)
      issue_report = write_scan_issue_report
      incomplete = @scan_issues.any? { |issue| %w[unreadable_directory unreadable_entry unreadable_file].include?(issue.fetch("kind")) }
      if incomplete && ENV["ALLOW_INCOMPLETE_MANIFEST"].to_s != "1"
        raise IncompleteScan,
          "Manifest scan was incomplete and the existing cache was preserved. "           "Review #{issue_report}. Re-run after filesystem access stabilises."
      end

      payload = {
        "version" => VERSION,
        "generated_at" => Time.now.utc.iso8601,
        "root" => @root,
        "scope" => "full",
        "term_index_fingerprint" => term_index_fingerprint_for_documents(scanned),
        "documents" => scanned
      }

      @cache_store.write_json(CACHE_PATH, payload)
      load_from_payload(payload)
      progress("manifest scan complete: #{@documents.length} documents")
      self
    end

    def document(id)
      # Most search and export operations only iterate the manifest. Building a
      # second 494,000-entry Hash eagerly wastes hundreds of megabytes in those
      # processes. Construct the lookup table only for callers that actually ask
      # for a document by ID.
      @documents_by_id ||= @documents.index_by { |doc| doc["id"].to_s }
      @documents_by_id[id.to_s]
    end

    def filtered(filters = {})
      filters = stringify_filters(filters)
      roles = normalized_roles(filters["document_roles"])
      include_folders = normalized_paths(filters["include_folders"])
      exclude_folders = normalized_paths(filters["exclude_folders"])

      @documents.select do |doc|
        role = doc["document_role"].presence || DocumentRole.classify(doc["path"])
        next false unless roles.include?(role)
        next false unless DocumentRole.searchable?(role)
        next false if doc["searchable_body"] == false || doc["size"].to_i.zero?
        next false unless included_folder?(doc, include_folders)
        next false if excluded_folder?(doc, exclude_folders)

        match_filter?(doc, "nation", filters["nation"]) &&
          match_filter?(doc, "period", filters["period"]) &&
          match_filter?(doc, "region", filters["region"]) &&
          match_filter?(doc, "author", filters["author"]) &&
          match_year_filter?(doc, filters["year_start"], filters["year_end"])
      end
    end

    def default_search_documents
      @default_search_documents ||= filtered("document_roles" => DocumentRole::DEFAULT_ROLES)
    end

    def term_index_fingerprint
      @term_index_fingerprint ||= @stored_term_index_fingerprint.presence || term_index_fingerprint_for_documents(default_search_documents)
    end

    private

    def scan_documents(cached_documents: nil)
      cached_by_path = Array(cached_documents).index_by { |doc| doc["path"].to_s }
      documents = []
      seen_files = 0
      skipped_files = 0

      each_txt_path do |absolute_path|
        relative_path = relative_path_for(absolute_path)

        stat = File.stat(absolute_path)
        metadata_path = @metadata_store.metadata_path_for(relative_path)
        fingerprint = fingerprint_for(stat, metadata_path)
        cached = cached_by_path[relative_path]

        document = if cached && cached["fingerprint"] == fingerprint && cached.key?("searchable_body")
          cached
        else
          build_document(relative_path, absolute_path, stat, fingerprint)
        end

        if document && document["searchable_body"]
          documents << document
        else
          skipped_files += 1
          progress("manifest excluded non-searchable body: #{relative_path}") if @debug_dirs
        end

        seen_files += 1
        if @progress_every.positive? && (seen_files % @progress_every).zero?
          progress("manifest: #{seen_files} .txt files indexed; latest #{relative_path}")
        end

        break if @max_files.positive? && seen_files >= @max_files
      rescue InvalidUtf8Document => e
        skipped_files += 1
        record_scan_issue("invalid_utf8", absolute_path, e)
        progress("manifest excluded invalid UTF-8 file #{relative_display(absolute_path)}")
        next
      rescue Errno::ENOENT, Errno::EACCES, Errno::EIO, Encoding::CompatibilityError => e
        skipped_files += 1
        record_scan_issue("unreadable_file", absolute_path, e)
        progress("manifest skipped file #{absolute_path}: #{e.class}: #{e.message}")
        next
      end

      progress("manifest: #{seen_files} files indexed, #{skipped_files} files skipped")
      documents
    end

    # Avoid Dir.glob("**/*.txt") here.
    #
    # On WSL + OneDrive, one bad readdir can make a single huge glob abort or sit
    # inside uninterruptible disk I/O. This walker gives progress output and makes
    # unreadable directories local damage instead of killing the whole scan.
    def each_txt_path
      return enum_for(:each_txt_path) unless block_given?

      dirs_seen = 0
      files_seen = 0
      stack = [@root]

      until stack.empty?
        directory = stack.pop
        dirs_seen += 1

        if @debug_dirs
          progress("manifest reading directory: #{relative_display(directory)}")
        elsif @dir_progress_every.positive? && (dirs_seen % @dir_progress_every).zero?
          progress("manifest: #{dirs_seen} directories visited, #{files_seen} .txt candidates found; current #{relative_display(directory)}")
        end

        safe_children(directory).each do |entry|
          next if entry.start_with?(".")
          next if skip_dir_name?(entry)

          absolute_path = File.join(directory, entry)
          lstat = File.lstat(absolute_path)
          next if lstat.symlink?

          if lstat.directory?
            stack << absolute_path
          elsif lstat.file? && entry.downcase.end_with?(".txt")
            files_seen += 1
            yield absolute_path
          end
        rescue Errno::ENOENT, Errno::EACCES, Errno::EIO, Encoding::CompatibilityError => e
          record_scan_issue("unreadable_entry", absolute_path, e)
          progress("manifest skipped entry #{absolute_path}: #{e.class}: #{e.message}")
          next
        end
      end
    end

    def safe_children(directory)
      attempts = 0
      begin
        attempts += 1
        Dir.children(directory).sort
      rescue Errno::ENOENT, Errno::EACCES, Errno::EIO, Encoding::CompatibilityError => e
        if attempts < @read_retries
          progress("manifest retrying directory #{relative_display(directory)} after #{e.class} (attempt #{attempts}/#{@read_retries})")
          sleep(0.25 * attempts)
          retry
        end
        record_scan_issue("unreadable_directory", directory, e)
        progress("manifest skipped unreadable directory #{directory}: #{e.class}: #{e.message}")
        []
      end
    end

    def build_document(relative_path, absolute_path, stat, fingerprint)
      metadata = @metadata_store.search_metadata_for_path(relative_path)
      path_metadata = metadata_from_path(relative_path)
      merged = path_metadata.merge(metadata) { |_key, path_value, json_value| json_value.presence || path_value }

      role = DocumentRole.classify(relative_path)
      body_stats = searchable_body_stats(absolute_path)

      {
        "id" => merged["document_id"].presence&.to_s || stable_id(relative_path),
        "work_id" => merged["work_id"].presence&.to_s,
        "path" => relative_path,
        "folder_path" => DocumentRole.folder_path(relative_path),
        "document_role" => role,
        "canonical_parent_path" => DocumentRole.canonical_parent_path(relative_path),
        "title" => merged["title"].presence || File.basename(relative_path, ".txt"),
        "work" => merged["work"].to_s,
        "author" => merged["author"].to_s,
        "date_text" => merged["date_text"].to_s,
        "nation" => merged["nation"].to_s,
        "corpus_root" => merged["corpus_root"].to_s,
        "macro_region" => merged["macro_region"].to_s,
        "period" => merged["period"].to_s,
        "polity" => merged["polity"].to_s,
        "region" => merged["region"].to_s,
        "category" => merged["category"].to_s,
        "year_start" => integer_or_nil(merged["year_start"]),
        "year_end" => integer_or_nil(merged["year_end"]),
        "size" => stat.size,
        "mtime" => stat.mtime.to_f,
        "searchable_body" => body_stats.fetch("searchable_body"),
        "searchable_characters" => body_stats.fetch("searchable_characters"),
        "body_fingerprint" => body_stats.fetch("body_fingerprint"),
        "fingerprint" => fingerprint
      }
    end


    # A corpus document must contain at least one searchable character after
    # punctuation/whitespace normalisation. Physically non-empty punctuation-only
    # placeholders are excluded from search and reported separately by maintenance.
    def searchable_body_stats(absolute_path)
      raw = File.binread(absolute_path).force_encoding(Encoding::UTF_8)
      unless raw.valid_encoding?
        raise InvalidUtf8Document, "invalid UTF-8 byte sequence"
      end

      body = DocumentReader.parse(raw).body.to_s.delete("\uFEFF")
      normalized = NormalizedText.build(body, punctuation: "ignore")
      {
        "searchable_body" => normalized.units.any?,
        "searchable_characters" => normalized.units.length,
        "body_fingerprint" => Digest::SHA256.hexdigest(body)
      }
    end

    def record_scan_issue(kind, path, error = nil)
      @scan_issues << {
        "kind" => kind,
        "path" => relative_display(path),
        "error_class" => error&.class&.name.to_s,
        "message" => error&.message.to_s
      }
    end

    def write_scan_issue_report
      directory = Rails.root.join("tmp", "corpus_search_manifest_audit")
      FileUtils.mkdir_p(directory)
      path = directory.join("manifest_scan_issues.csv")
      CSV.open(path, "w", encoding: "UTF-8", write_headers: true,
        headers: %w[kind path error_class message]) do |csv|
        @scan_issues.each { |issue| csv << issue }
      end
      progress("manifest audit report: #{path} (#{@scan_issues.length} issues)")
      path
    end

    def metadata_from_path(relative_path)
      # Under the JSON metadata system, folder depth is not a metadata schema.
      # Compilation titles and work folders previously leaked into `region`
      # because the second path component after clean/ was guessed to be a
      # region. Only the top-level corpus root is structurally reliable.
      { "corpus_root" => relative_path.split("/").first.to_s }
    end

    def skip_dir_name?(entry)
      configured = ENV.fetch("CORPUS_SEARCH_SKIP_DIRS", "").split(/[,:;]/).map(&:strip).reject(&:empty?)
      (DEFAULT_SKIP_DIRS + configured).include?(entry)
    end

    def relative_path_for(absolute_path)
      Pathname(absolute_path).relative_path_from(Pathname(@root)).to_s.tr("\\", "/")
    end

    def relative_display(absolute_path)
      relative_path_for(absolute_path)
    rescue ArgumentError
      absolute_path.to_s
    end

    def stable_id(relative_path)
      Digest::SHA256.hexdigest(relative_path).first(24)
    end

    def fingerprint_for(stat, metadata_path = nil)
      metadata_fingerprint = if metadata_path && File.file?(metadata_path)
        metadata_stat = File.stat(metadata_path)
        ":metadata=#{metadata_stat.size}:#{metadata_stat.mtime.to_f}"
      else
        ":metadata=none"
      end
      "#{stat.size}:#{stat.mtime.to_f}#{metadata_fingerprint}"
    end

    def load_from_payload(payload)
      @generated_at = payload["generated_at"].to_s
      @documents = Array(payload["documents"])
      @documents_by_id = nil
      @default_search_documents = nil
      @stored_term_index_fingerprint = payload["term_index_fingerprint"].to_s
      @term_index_fingerprint = nil
    end

    def stringify_filters(filters)
      filters.to_h.transform_keys(&:to_s).transform_values do |value|
        value.is_a?(Array) ? value : value.to_s.strip
      end
    end

    def normalized_roles(values)
      roles = Array(values).flat_map { |value| value.to_s.split(",") }
        .map(&:strip)
        .select { |role| DocumentRole::SEARCHABLE_ROLES.include?(role) }
        .uniq

      roles.presence || DocumentRole::DEFAULT_ROLES
    end

    def normalized_paths(values)
      Array(values).flat_map { |value| value.to_s.split("\n") }
        .map { |path| path.strip.tr("\\", "/").sub(%r{\A/+}, "").sub(%r{/+\z}, "") }
        .reject(&:empty?)
        .uniq
    end

    def included_folder?(doc, folders)
      return true if folders.empty?

      folders.any? { |folder| path_within?(doc["path"], folder) }
    end

    def excluded_folder?(doc, folders)
      folders.any? { |folder| path_within?(doc["path"], folder) }
    end

    def path_within?(path, folder)
      normalized_path = path.to_s.tr("\\", "/").sub(%r{\A/+}, "")
      normalized_path == folder || normalized_path.start_with?("#{folder}/")
    end

    def cache_current?(payload)
      payload.is_a?(Hash) &&
        payload["version"].to_i == VERSION &&
        payload["root"].to_s == @root
    end

    def term_index_fingerprint_for_documents(documents)
      digest = Digest::SHA256.new
      digest << "manifest-role-profile:canonical-v1\n"
      Array(documents).each do |doc|
        role = doc["document_role"].presence || "canonical"
        next unless DocumentRole.default?(role)

        digest << doc["id"].to_s
        digest << "\0"
        digest << doc["fingerprint"].to_s
        digest << "\0"
        digest << role.to_s
        digest << "\n"
      end
      digest.hexdigest
    end

    def match_filter?(doc, key, value)
      return true if value.blank?

      doc[key].to_s.include?(value)
    end

    def match_year_filter?(doc, from, to)
      return true if from.blank? && to.blank?

      start_year = doc["year_start"]
      end_year = doc["year_end"] || start_year
      return false if start_year.nil? && end_year.nil?

      from_i = integer_or_nil(from)
      to_i = integer_or_nil(to)
      return false if from_i && end_year && end_year < from_i
      return false if to_i && start_year && start_year > to_i

      true
    end

    def integer_or_nil(value)
      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end

    def integer_env(name, default)
      Integer(ENV.fetch(name, default.to_s))
    rescue ArgumentError, TypeError
      default
    end

    def progress(message)
      return if @silent

      $stdout.sync = true
      puts "[corpus_search] #{message}"
      Rails.logger.info("[corpus_search] #{message}") if defined?(Rails)
    end
  end
end
