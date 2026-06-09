# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
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
      @root = Pathname(root || Rails.root.join("storage", "corpus_search"))
      FileUtils.mkdir_p(@root)
    end

    def read_json(relative_path)
      path = absolute(relative_path)
      return nil unless path.file?

      payload = if path.extname == ".gz"
        Zlib::GzipReader.open(path, &:read)
      else
        path.read
      end

      JSON.parse(payload)
    rescue JSON::ParserError, Zlib::GzipFile::Error, Errno::ENOENT
      nil
    end

    def write_json(relative_path, object, gzip: true)
      path = absolute(relative_path)
      FileUtils.mkdir_p(path.dirname)

      # Compact JSON matters for term indexes. Pretty JSON is pleasant to read,
      # but it creates much larger strings for hundreds of thousands of entries.
      json = JSON.generate(object)
      tmp_path = path.dirname.join(".#{path.basename}.#{$$}.tmp")

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

    def absolute(relative_path)
      relative = relative_path.to_s.sub(%r{\A/+}, "")
      @root.join(relative)
    end

    def self.hash_key(value)
      Digest::SHA256.hexdigest(value.to_s)
    end
  end
end
