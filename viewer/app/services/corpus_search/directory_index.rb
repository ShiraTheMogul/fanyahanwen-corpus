# frozen_string_literal: true

require "csv"
require "pathname"
require "time"

module CorpusSearch
  # Rebuildable full directory-path catalogue used by maintenance compilers.
  #
  # Unlike FolderTree, this keeps all clean-corpus directories, including empty
  # polity placeholders. Web requests never load or scan it. Atlas compilation
  # uses it to understand deliberate folder layers without guessing from the
  # presence of text files alone.
  class DirectoryIndex
    VERSION = 1
    CACHE_PATH = "directory_index-v1.json.gz"
    DEFAULT_PROGRESS_EVERY = 5_000

    attr_reader :paths, :generated_at, :source

    def self.load(cache_store: CacheStore.new)
      payload = cache_store.read_json(CACHE_PATH)
      index = new(cache_store: cache_store)
      index.send(:load_payload!, payload)
      index
    end

    def self.load_or_build(root: Rails.configuration.x.corpus_root, cache_store: CacheStore.new)
      payload = cache_store.read_json(CACHE_PATH)
      index = new(cache_store: cache_store)
      return index.send(:load_payload!, payload) if index.send(:current_payload?, payload)

      index.build!(root: root)
    end

    def self.build!(root: Rails.configuration.x.corpus_root, cache_store: CacheStore.new)
      new(cache_store: cache_store).build!(root: root)
    end

    def initialize(cache_store: CacheStore.new)
      @cache_store = cache_store
      @paths = []
      @generated_at = ""
      @source = ""
      @progress_every = Integer(ENV.fetch("CORPUS_DIRECTORY_PROGRESS_EVERY", DEFAULT_PROGRESS_EVERY.to_s))
      @read_retries = [Integer(ENV.fetch("CORPUS_DIRECTORY_READ_RETRIES", "3")), 1].max
    end

    def build!(root:)
      root = Pathname.new(root.to_s).expand_path
      raise ArgumentError, "Corpus root does not exist: #{root}" unless root.directory?

      paths = scan_clean_directories(root)
      payload = {
        "version" => VERSION,
        "generated_at" => Time.now.utc.iso8601,
        "root" => root.to_s,
        "source" => "filesystem",
        "paths" => paths
      }
      @cache_store.write_json(CACHE_PATH, payload)
      load_payload!(payload)
    end

    def empty? = paths.empty?

    private

    def scan_clean_directories(root)
      results = []
      roots = safe_children(root).filter_map do |entry|
        candidate = root.join(entry, "clean")
        candidate if candidate.directory?
      rescue Errno::ENOENT, Errno::EACCES, Errno::EIO, Encoding::CompatibilityError
        nil
      end

      stack = roots.map { |clean| [clean, clean.relative_path_from(root).to_s.tr("\\", "/")] }
      seen = 0
      until stack.empty?
        directory, relative = stack.pop
        safe_children(directory).each do |entry|
          absolute = directory.join(entry)
          next unless absolute.directory?

          child_relative = [relative, entry].join("/")
          child_relative = child_relative.dup.force_encoding(Encoding::UTF_8)
          raise Encoding::CompatibilityError, "Invalid UTF-8 directory path: #{child_relative.inspect}" unless child_relative.valid_encoding?
          results << child_relative
          stack << [absolute, child_relative]
          seen += 1
          puts "[corpus_search] directory index: #{seen} directories; current #{child_relative}" if @progress_every.positive? && (seen % @progress_every).zero?
        rescue Errno::ENOENT, Errno::EACCES, Errno::EIO, Encoding::CompatibilityError => error
          warn "[corpus_search] directory index skipped #{absolute}: #{error.class}: #{error.message}"
        end
      end
      results.sort
    end

    def safe_children(directory)
      attempts = 0
      begin
        attempts += 1
        Dir.children(directory).map do |entry|
          value = entry.dup.force_encoding(Encoding::UTF_8)
          raise Encoding::CompatibilityError, "Invalid UTF-8 directory entry: #{entry.inspect}" unless value.valid_encoding?
          value
        end.sort
      rescue Errno::ENOENT, Errno::EACCES, Errno::EIO, Encoding::CompatibilityError => error
        if attempts < @read_retries
          sleep(0.25 * attempts)
          retry
        end
        warn "[corpus_search] directory index skipped directory #{directory}: #{error.class}: #{error.message}"
        []
      end
    end

    def load_payload!(payload)
      raise ArgumentError, "Directory index is missing or malformed" unless current_payload?(payload)

      @generated_at = payload["generated_at"].to_s
      @source = payload["source"].to_s
      @paths = Array(payload["paths"]).map(&:to_s).freeze
      self
    end

    def current_payload?(payload)
      payload.is_a?(Hash) && payload["version"].to_i == VERSION && payload["paths"].is_a?(Array)
    end
  end
end
