# frozen_string_literal: true

require "digest"
require "pathname"
require "time"

module CorpusSearch
  # Rebuildable index of corpus files and their light metadata.
  #
  # The corpus .txt files remain the source of truth. This manifest only records
  # enough information to find files safely, filter them, and notice changes.
  class Manifest
    DEFAULT_SKIP_DIRS = %w[.git .svn node_modules tmp log storage bak vendor].freeze
    VERSION = 3
    CACHE_PATH = "manifest.json.gz"
    FRONT_MATTER_READ_BYTES = 65_536

    attr_reader :documents, :generated_at

    def self.load(root: Rails.configuration.x.corpus_root, cache_store: CacheStore.new, refresh: false, force: false)
      manifest = new(root: root, cache_store: cache_store)
      if refresh || force
        manifest.refresh!(force: force)
      else
        manifest.load_cached_or_refresh!
      end
      manifest
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
      scanned = scan_documents(cached_documents: cached_documents)

      payload = {
        "version" => VERSION,
        "generated_at" => Time.now.utc.iso8601,
        "root" => @root,
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
      @term_index_fingerprint ||= begin
        digest = Digest::SHA256.new
        digest << "manifest-role-profile:canonical-v1\n"
        default_search_documents.each do |doc|
          digest << doc["id"].to_s
          digest << "\0"
          digest << doc["fingerprint"].to_s
          digest << "\0"
          digest << (doc["document_role"].presence || "canonical").to_s
          digest << "\n"
        end
        digest.hexdigest
      end
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
        fingerprint = fingerprint_for(stat)
        cached = cached_by_path[relative_path]

        documents << if cached && cached["fingerprint"] == fingerprint
                       cached
                     else
                       build_document(relative_path, absolute_path, stat, fingerprint)
                     end

        seen_files += 1
        if @progress_every.positive? && (seen_files % @progress_every).zero?
          progress("manifest: #{seen_files} .txt files indexed; latest #{relative_path}")
        end

        break if @max_files.positive? && seen_files >= @max_files
      rescue Errno::ENOENT, Errno::EACCES, Errno::EIO, Encoding::CompatibilityError => e
        skipped_files += 1
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
          progress("manifest skipped entry #{absolute_path}: #{e.class}: #{e.message}")
          next
        end
      end
    end

    def safe_children(directory)
      Dir.children(directory).sort
    rescue Errno::ENOENT, Errno::EACCES, Errno::EIO, Encoding::CompatibilityError => e
      progress("manifest skipped unreadable directory #{directory}: #{e.class}: #{e.message}")
      []
    end

    def build_document(relative_path, absolute_path, stat, fingerprint)
      raw_header = read_front_matter_sample(absolute_path)
      metadata, = FrontMatter.split(raw_header)
      path_metadata = metadata_from_path(relative_path)
      merged = path_metadata.merge(metadata) { |_key, path_value, header_value| header_value.presence || path_value }

      role = DocumentRole.classify(relative_path)

      {
        "id" => stable_id(relative_path),
        "path" => relative_path,
        "folder_path" => DocumentRole.folder_path(relative_path),
        "document_role" => role,
        "canonical_parent_path" => DocumentRole.canonical_parent_path(relative_path),
        "title" => merged["title"].presence || File.basename(relative_path, ".txt"),
        "work" => merged["work"].to_s,
        "author" => merged["author"].to_s,
        "date_text" => merged["date_text"].to_s,
        "nation" => merged["nation"].to_s,
        "period" => merged["period"].to_s,
        "region" => merged["region"].to_s,
        "category" => merged["category"].to_s,
        "year_start" => integer_or_nil(merged["year_start"]),
        "year_end" => integer_or_nil(merged["year_end"]),
        "size" => stat.size,
        "mtime" => stat.mtime.to_f,
        "fingerprint" => fingerprint
      }
    end

    # The manifest only needs header/front-matter metadata. Reading the whole file
    # here is expensive and can block badly under WSL + OneDrive. The actual body
    # is read later only when a search needs that file.
    def read_front_matter_sample(absolute_path)
      sample = File.open(absolute_path, "rb") { |file| file.read(FRONT_MATTER_READ_BYTES).to_s }
      sample.force_encoding("UTF-8")
      sample = sample.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
      sample.delete_prefix("\uFEFF")
    end

    def metadata_from_path(relative_path)
      parts = relative_path.split("/")
      layer_index = parts.index("clean") || parts.index("raw")
      after_clean = layer_index ? parts[(layer_index + 1)..] : parts

      {
        "nation" => parts.first.to_s,
        "period" => after_clean && after_clean.length > 1 ? after_clean.first.to_s : "",
        "region" => after_clean && after_clean.length > 2 ? after_clean[1].to_s : ""
      }
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

    def fingerprint_for(stat)
      "#{stat.size}:#{stat.mtime.to_f}"
    end

    def load_from_payload(payload)
      @generated_at = payload["generated_at"].to_s
      @documents = Array(payload["documents"])
      @documents_by_id = nil
      @default_search_documents = nil
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
