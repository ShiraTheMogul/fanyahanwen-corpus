# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "zlib"

module CorpusSearch
  # Filesystem-backed cache/index storage.
  #
  # This deliberately does not use Rails.cache, because Solid Cache may be
  # database-backed. Corpus search indexes and query caches should stay disposable
  # and file-native.
  class CacheStore
    attr_reader :root

    def initialize(root: nil)
      configured_root = ENV["CORPUS_SEARCH_CACHE_ROOT"].to_s.strip
      default_root = configured_root.present? ? configured_root : Rails.root.join("storage", "corpus_search")
      @root = Pathname(root || default_root).expand_path
      FileUtils.mkdir_p(@root)
    end

    # SQLite's WAL journal is excellent on a native local filesystem, but it is
    # a poor fit for Windows-mounted WSL paths such as /mnt/c. Those paths have
    # different locking and metadata costs, and the audit observed long I/O
    # stalls there. DELETE mode is slower than WAL on native Linux, but much more
    # predictable on the mounted Windows filesystem.
    def sqlite_journal_mode
      windows_mounted_wsl_path? ? "DELETE" : "WAL"
    end

    def windows_mounted_wsl_path?
      @root.to_s.match?(%r{\A/mnt/[a-z](?:/|\z)}i)
    end

    def read_json(relative_path, freeze: false)
      path = absolute(relative_path)
      return nil unless path.file?

      payload = if path.extname == ".gz"
        Zlib::GzipReader.open(path, &:read)
      else
        path.read
      end

      JSON.parse(payload, freeze: freeze)
    rescue JSON::ParserError, Zlib::GzipFile::Error, Errno::ENOENT
      nil
    end

    def write_json(relative_path, object, gzip: true)
      path = absolute(relative_path)
      FileUtils.mkdir_p(path.dirname)

      # Compact JSON matters for term indexes. Pretty JSON is pleasant to read,
      # but it creates much larger strings for hundreds of thousands of entries.
      json = JSON.generate(object)
      # PID alone is not unique when Puma threads write concurrently. Two
      # requests in the same process previously shared one temporary filename;
      # the first rename consumed it and the second raised Errno::ENOENT.
      tmp_path = path.dirname.join(
        ".#{path.basename}.#{$$}.#{Thread.current.object_id}.#{SecureRandom.hex(6)}.tmp"
      )

      if gzip || path.extname == ".gz"
        Zlib::GzipWriter.open(tmp_path.to_s) { |gz| gz.write(json) }
      else
        tmp_path.write(json)
      end

      FileUtils.mv(tmp_path, path)
      path
    ensure
      FileUtils.rm_f(tmp_path) if defined?(tmp_path) && tmp_path
    end

    def delete(relative_path)
      path = absolute(relative_path)
      FileUtils.rm_f(path)
    end

    def exist?(relative_path)
      absolute(relative_path).file?
    end

    def absolute(relative_path)
      relative = relative_path.to_s.sub(%r{\A/+}, "")
      @root.join(relative)
    end

    def self.hash_key(value)
      Digest::SHA256.hexdigest(value.to_s)
    end
  end
end
