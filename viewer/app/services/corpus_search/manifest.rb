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
    VERSION = 9
    CACHE_PATH = "manifest.json.gz"
    QUERY_CACHE_VERSION = 2
    QUERY_CACHE_META_PATH = "manifest-query-v2.json.gz"
    QUERY_CACHE_DIRECTORY = "manifest-query-v2"
    QUERY_DOCUMENT_FIELDS = %w[
      id work_id path folder_path document_role canonical_parent_path
      title work author date_text nation corpus_root macro_region period polity region
      category categories
      year_start year_end date_resolution_source era_id era_name era_year era_dynasty
      compilation_work_id compilation_title compilation_period compilation_polity compilation_date_text
      compilation_year_start compilation_year_end
      compilation_date_resolution_source compilation_era_id compilation_era_name
      compilation_era_year compilation_era_dynasty
      size searchable_body searchable_characters body_fingerprint fingerprint
    ].freeze
    FILTER_FIELDS = %w[nation polity period region author categories].freeze
    FRONT_MATTER_READ_BYTES = 65_536

    class CacheMissing < StandardError; end
    class IncompleteScan < StandardError; end
    class InvalidUtf8Document < StandardError; end

    attr_reader :generated_at, :scan_issues

    # Full-manifest access remains available for maintenance callers. Query-time
    # manifests keep only their requested role slices in memory; asking for
    # #documents explicitly falls back to the administrator-built full cache.
    def documents
      return @documents if @documents

      load_full_documents_for_compatibility!
      @documents
    end

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
      # Web requests read prebuilt role slices instead of parsing and filtering
      # the complete ~500k-document manifest. Refreshes remain maintenance-only.
      manifest = new(root: root, cache_store: cache_store)
      roles = manifest.send(:normalized_roles, query.respond_to?(:document_roles) ? query.document_roles : nil)
      manifest.load_query_cache!(roles: roles)
    end

    # Build query-role caches from the existing administrator manifest without
    # touching the corpus filesystem. Useful immediately after deploying a cache
    # format change; normal rebuild_manifest runs create these automatically.
    def self.rebuild_query_caches!(root: Rails.configuration.x.corpus_root, cache_store: CacheStore.new)
      manifest = new(root: root, cache_store: cache_store).load_cached!
      manifest.send(
        :write_query_role_caches!,
        manifest.documents,
        generated_at: manifest.generated_at,
        term_index_fingerprint: manifest.term_index_fingerprint
      )
      manifest
    end

    def initialize(root:, cache_store: CacheStore.new)
      @root = File.realpath(root.to_s)
      @cache_store = cache_store
      @documents = []
      @query_documents = nil
      @loaded_query_roles = nil
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

    def load_query_cache!(roles:)
      selected_roles = normalized_roles(roles)
      meta = @cache_store.read_json(QUERY_CACHE_META_PATH, freeze: true)
      unless query_cache_meta_current?(meta)
        raise CacheMissing, query_cache_missing_message
      end

      generation = meta["generation"].to_s
      role_paths = meta["roles"]
      query_documents = []

      selected_roles.each do |role|
        relative_path = role_paths[role].to_s
        raise CacheMissing, query_cache_missing_message if relative_path.empty?

        payload = @cache_store.read_json(relative_path, freeze: true)
        unless query_role_payload_current?(payload, generation: generation, role: role)
          raise CacheMissing, query_cache_missing_message
        end
        query_documents.concat(Array(payload["documents"]))
      end

      @generated_at = meta["manifest_generated_at"].to_s
      @stored_term_index_fingerprint = meta["term_index_fingerprint"].to_s
      @term_index_fingerprint = nil
      @query_documents = query_documents.freeze
      @loaded_query_roles = selected_roles.freeze
      @documents = nil
      @documents_by_id = nil
      @default_search_documents = nil
      progress("query manifest loaded from role cache: #{@query_documents.length} documents (#{selected_roles.join(', ')})")
      self
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
          "Manifest scan was incomplete and the existing cache was preserved. " \
          "Review #{issue_report}. Re-run after filesystem access stabilises."
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
      write_query_role_caches!(
        scanned,
        generated_at: payload["generated_at"],
        term_index_fingerprint: payload["term_index_fingerprint"]
      )
      load_from_payload(payload)
      progress("manifest scan complete: #{@documents.length} documents")
      self
    end

    def document(id)
      # Most search and export operations only iterate the manifest. Build a
      # lookup table lazily, and prefer the already-small query slice when one is
      # loaded.
      source = @documents || @query_documents || documents
      @documents_by_id ||= source.index_by { |doc| doc["id"].to_s }
      @documents_by_id[id.to_s]
    end

    def filtered(filters = {})
      filters = stringify_filters(filters)
      roles = normalized_roles(filters["document_roles"])
      include_folders = normalized_paths(filters["include_folders"])
      exclude_folders = normalized_paths(filters["exclude_folders"])
      active_filters = FILTER_FIELDS.filter_map do |field|
        value = filters[field].to_s
        [field, value] unless value.empty?
      end
      year_filter_requested = filters["year_start"].present? || filters["year_end"].present?
      from_year = integer_or_nil(filters["year_start"])
      to_year = integer_or_nil(filters["year_end"])

      source = @query_documents || documents
      role_filter_needed = !query_roles_exact?(roles)

      # The common targeted-search case is now O(1): load_for_query already
      # selected the requested role slice and there are no scope predicates.
      if !role_filter_needed && include_folders.empty? && exclude_folders.empty? &&
         active_filters.empty? && !year_filter_requested
        return source
      end

      role_lookup = role_filter_needed ? roles.to_h { |role| [role, true] } : nil

      source.select do |doc|
        if role_filter_needed
          role = doc["document_role"].to_s
          role = DocumentRole.classify(doc["path"]) if role.empty?
          next false unless role_lookup.key?(role)
        end

        path = doc["path"].to_s
        next false if include_folders.any? && !path_in_folders?(path, include_folders)
        next false if exclude_folders.any? && path_in_folders?(path, exclude_folders)
        next false unless active_filters.all? { |field, value| filter_value_matches?(doc[field], value) }

        if year_filter_requested
          start_year = doc["year_start"]
          end_year = doc["year_end"] || start_year
          next false if start_year.nil? && end_year.nil?
          next false if from_year && end_year && end_year < from_year
          next false if to_year && start_year && start_year > to_year
        end

        true
      end
    end

    def default_search_documents
      return @query_documents if query_roles_exact?(DocumentRole::DEFAULT_ROLES)

      @default_search_documents ||= filtered("document_roles" => DocumentRole::DEFAULT_ROLES)
    end

    def term_index_fingerprint
      @term_index_fingerprint ||= @stored_term_index_fingerprint.presence || term_index_fingerprint_for_documents(default_search_documents)
    end

    private

    def write_query_role_caches!(documents, generated_at:, term_index_fingerprint:)
      previous_meta = @cache_store.read_json(QUERY_CACHE_META_PATH, freeze: true)
      previous_generation = previous_meta.is_a?(Hash) ? previous_meta["generation"].to_s : ""
      generation = Digest::SHA256.hexdigest(
        [VERSION, generated_at, term_index_fingerprint].join("\0")
      )[0, 20]

      grouped = DocumentRole::SEARCHABLE_ROLES.to_h { |role| [role, []] }
      Array(documents).each do |doc|
        role = doc["document_role"].to_s
        next unless grouped.key?(role)
        next if doc["searchable_body"] == false || doc["size"].to_i.zero?

        grouped[role] << compact_query_document(doc)
      end

      role_paths = {}
      grouped.each do |role, role_documents|
        relative_path = File.join(QUERY_CACHE_DIRECTORY, generation, "#{role}.json.gz")
        @cache_store.write_json(
          relative_path,
          {
            "version" => QUERY_CACHE_VERSION,
            "root" => @root,
            "generation" => generation,
            "role" => role,
            "documents" => role_documents
          }
        )
        role_paths[role] = relative_path
      end

      @cache_store.write_json(
        QUERY_CACHE_META_PATH,
        {
          "version" => QUERY_CACHE_VERSION,
          "manifest_version" => VERSION,
          "root" => @root,
          "generation" => generation,
          "manifest_generated_at" => generated_at.to_s,
          "term_index_fingerprint" => term_index_fingerprint.to_s,
          "roles" => role_paths
        }
      )

      cleanup_query_cache_generations!(keep: [generation, previous_generation].reject(&:empty?))
      progress("query manifest role caches built: #{grouped.sum { |_role, rows| rows.length }} documents")
    end

    def compact_query_document(doc)
      QUERY_DOCUMENT_FIELDS.each_with_object({}) do |field, output|
        output[field] = doc[field] if doc.key?(field)
      end
    end

    def cleanup_query_cache_generations!(keep:)
      directory = @cache_store.absolute(QUERY_CACHE_DIRECTORY)
      return unless directory.directory?

      directory.children.each do |child|
        next unless child.directory?
        next if keep.include?(child.basename.to_s)

        FileUtils.rm_rf(child)
      end
    rescue Errno::ENOENT, Errno::EACCES, Errno::EIO
      nil
    end

    def query_cache_meta_current?(payload)
      payload.is_a?(Hash) &&
        payload["version"].to_i == QUERY_CACHE_VERSION &&
        payload["manifest_version"].to_i == VERSION &&
        payload["root"].to_s == @root &&
        payload["generation"].present? &&
        payload["roles"].is_a?(Hash)
    end

    def query_role_payload_current?(payload, generation:, role:)
      payload.is_a?(Hash) &&
        payload["version"].to_i == QUERY_CACHE_VERSION &&
        payload["root"].to_s == @root &&
        payload["generation"].to_s == generation.to_s &&
        payload["role"].to_s == role.to_s &&
        payload["documents"].is_a?(Array)
    end

    def query_cache_missing_message
      "The corpus search query cache has not been built for this manifest. " \
        "Run bin/rails runner 'CorpusSearch::Manifest.rebuild_query_caches!' as a maintenance command."
    end

    def query_roles_exact?(roles)
      return false unless @query_documents && @loaded_query_roles

      @loaded_query_roles.sort == Array(roles).sort
    end

    def load_full_documents_for_compatibility!
      cached = @cache_store.read_json(CACHE_PATH, freeze: true)
      unless cache_current?(cached)
        raise CacheMissing, "The corpus search manifest has not been built. Run bin/rails corpus_search:rebuild_manifest as a maintenance command."
      end

      @documents = Array(cached["documents"])
    end

    def path_in_folders?(path, folders)
      folders.any? { |folder| path == folder || path.start_with?("#{folder}/") }
    end

    def scan_documents(cached_documents: nil)
      cached_by_path = Array(cached_documents).index_by { |doc| doc["path"].to_s }
      documents = []
      seen_files = 0
      skipped_files = 0

      each_txt_path do |absolute_path|
        relative_path = relative_path_for(absolute_path)

        stat = File.stat(absolute_path)
        metadata_paths = @metadata_store.metadata_dependency_paths_for(relative_path)
        fingerprint = fingerprint_for(stat, metadata_paths)
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
      categories = Array(merged["categories"]).map(&:to_s).map(&:strip).reject(&:empty?).uniq

      year_start = integer_or_nil(merged["year_start"])
      year_end = integer_or_nil(merged["year_end"])
      work_resolution = resolve_historical_date(
        date_text: merged["date_text"],
        period: merged["period"],
        polity: merged["polity"],
        only_if_missing: year_start.nil? && year_end.nil?
      )
      if work_resolution
        year_start = work_resolution.year_start
        year_end = work_resolution.year_end
      end

      compilation_year_start = integer_or_nil(merged["compilation_year_start"])
      compilation_year_end = integer_or_nil(merged["compilation_year_end"])
      compilation_resolution = resolve_historical_date(
        date_text: merged["compilation_date_text"],
        period: merged["compilation_period"].presence || merged["period"],
        polity: merged["compilation_polity"].presence || merged["polity"],
        only_if_missing: compilation_year_start.nil? && compilation_year_end.nil?
      )
      if compilation_resolution
        compilation_year_start = compilation_resolution.year_start
        compilation_year_end = compilation_resolution.year_end
      end

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
        # `category` remains for compatibility. `categories` is authoritative.
        "category" => merged["category"].presence || categories.join("; "),
        "categories" => categories,
        "year_start" => year_start,
        "year_end" => year_end,
        "date_resolution_source" => work_resolution&.source.to_s.presence,
        "era_id" => work_resolution&.era_id,
        "era_name" => work_resolution&.era_name.to_s.presence,
        "era_year" => work_resolution&.era_year,
        "era_dynasty" => work_resolution&.dynasty.to_s.presence,
        "compilation_work_id" => merged["compilation_work_id"].presence&.to_s,
        "compilation_title" => merged["compilation_title"].to_s,
        "compilation_period" => merged["compilation_period"].to_s,
        "compilation_polity" => merged["compilation_polity"].to_s,
        "compilation_date_text" => merged["compilation_date_text"].to_s,
        "compilation_year_start" => compilation_year_start,
        "compilation_year_end" => compilation_year_end,
        "compilation_date_resolution_source" => compilation_resolution&.source.to_s.presence,
        "compilation_era_id" => compilation_resolution&.era_id,
        "compilation_era_name" => compilation_resolution&.era_name.to_s.presence,
        "compilation_era_year" => compilation_resolution&.era_year,
        "compilation_era_dynasty" => compilation_resolution&.dynasty.to_s.presence,
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

    def resolve_historical_date(date_text:, period:, polity:, only_if_missing:)
      return nil unless only_if_missing
      return nil if date_text.to_s.strip.empty?

      historical_date_resolver.resolve(
        date_text: date_text,
        period: period,
        polity: polity
      )
    rescue StandardError => e
      progress("historical date resolution skipped: #{e.class}: #{e.message}") if @debug_dirs
      nil
    end

    def historical_date_resolver
      @historical_date_resolver ||= CbdbHistoricalDateResolver.default
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

    def fingerprint_for(stat, metadata_paths = nil)
      dependencies = Array(metadata_paths).compact.select { |path| File.file?(path) }.sort_by(&:to_s)
      metadata_fingerprint = if dependencies.empty?
        ":metadata=none"
      else
        dependency_state = dependencies.map do |path|
          metadata_stat = File.stat(path)
          "#{path}:#{metadata_stat.size}:#{metadata_stat.mtime.to_f}"
        end.join("|")
        ":metadata=#{Digest::SHA256.hexdigest(dependency_state)}"
      end
      "#{stat.size}:#{stat.mtime.to_f}#{metadata_fingerprint}"
    end

    def load_from_payload(payload)
      @generated_at = payload["generated_at"].to_s
      @documents = Array(payload["documents"])
      @query_documents = nil
      @loaded_query_roles = nil
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

      filter_value_matches?(doc[key], value)
    end

    def filter_value_matches?(stored, value)
      Array(stored).any? { |entry| entry.to_s.include?(value.to_s) }
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
