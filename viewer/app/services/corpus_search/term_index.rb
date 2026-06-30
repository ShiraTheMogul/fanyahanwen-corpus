# frozen_string_literal: true

require "digest"
require "json"
require "set"
require "time"
require "tmpdir"

module CorpusSearch
  # On-demand index for one literal search term.
  #
  # It stores positive counts per file, not corpus text. A missing entry means
  # either "no hit" for a complete/current index, or "unknown" for a stale one.
  # If the manifest fingerprint changes, the index is rebuilt before it is used
  # interactively. Warming tasks write current indexes in batches.
  class TermIndex
    DEFAULT_BATCH_SIZE = 8

    def self.cache_path_for(term)
      File.join("term_indexes", "#{CacheStore.hash_key(term)}.json.gz")
    end

    # Efficient refresher for many single-character terms.
    #
    # The corpus is read once. Positive hits are spooled to small temporary files
    # and each final compressed term index is assembled one term at a time. This
    # keeps memory bounded without re-reading the entire corpus for every batch.
    def self.refresh_single_character_terms!(terms:, manifest:, cache_store: CacheStore.new, progress: nil, batch_size: nil, force: false)
      terms = terms.map(&:to_s).map(&:strip).select { |term| term.each_char.count == 1 }.uniq
      return 0 if terms.empty?

      # Retain the keyword for compatibility with older task invocations. The
      # one-pass spooler no longer needs a corpus-reading batch size.

      manifest_key = manifest_fingerprint(manifest)
      total_documents = manifest.documents.length
      terms_to_refresh = terms.reject do |term|
        next false if force

        current_for_manifest?(cache_store.read_json(cache_path_for(term)), manifest_key)
      end
      return terms.length if terms_to_refresh.empty?

      target_terms = terms_to_refresh.to_set
      fs = CorpusFs.new(root: Rails.configuration.x.corpus_root)
      files_read = 0
      files_skipped = 0

      Dir.mktmpdir("corpus-term-indexes") do |directory|
        paths = terms_to_refresh.to_h do |term|
          [term, File.join(directory, "#{CacheStore.hash_key(term)}.jsonl")]
        end
        buffers = terms_to_refresh.to_h { |term| [term, +""] }
        buffer_limit = [[16_777_216 / terms_to_refresh.length, 1_024].max, 65_536].min

        manifest.documents.each_with_index do |doc, index|
          body = body_for_doc(fs, doc)
          counts = Hash.new(0)
          body.each_char { |character| counts[character] += 1 if target_terms.include?(character) }

          counts.each do |term, count|
            buffers[term] << JSON.generate([doc["id"], doc["fingerprint"], count]) << "\n"
            flush_buffer!(paths.fetch(term), buffers.fetch(term)) if buffers.fetch(term).bytesize >= buffer_limit
          end

          files_read += 1
          progress&.call(index + 1, total_documents, files_read, files_skipped)
        rescue Errno::ENOENT, Errno::EACCES, Errno::EIO, SecurityError, Encoding::CompatibilityError => e
          files_skipped += 1
          progress&.call(index + 1, total_documents, files_read, files_skipped, e)
          next
        end

        buffers.each { |term, buffer| flush_buffer!(paths.fetch(term), buffer) }

        generated_at = Time.now.utc.iso8601
        terms_to_refresh.each do |term|
          entries = {}
          path = paths.fetch(term)

          if File.file?(path)
            File.foreach(path, chomp: true) do |line|
              doc_id, fingerprint, count = JSON.parse(line)
              entries[doc_id.to_s] = {
                "fingerprint" => fingerprint,
                "count" => count.to_i
              }
            end
          end

          payload = fresh_payload_for(
            term,
            manifest_fingerprint: manifest_key,
            total_documents: total_documents
          )
          payload["generated_at"] = generated_at
          payload["entries"] = entries
          cache_store.write_json(cache_path_for(term), payload)
        end
      end

      terms.length
    end

    def self.flush_buffer!(path, buffer)
      return if buffer.empty?

      File.open(path, "ab") { |file| file.write(buffer) }
      buffer.clear
    end
    private_class_method :flush_buffer!

    def initialize(term:, manifest:, cache_store: CacheStore.new)
      @term = term.to_s
      @manifest = manifest
      @cache_store = cache_store
      @cache_path = self.class.cache_path_for(@term)
      @payload = @cache_store.read_json(@cache_path) || self.class.fresh_payload_for(@term)
    end

    def refresh!
      manifest_key = self.class.manifest_fingerprint(@manifest)
      return self if self.class.current_for_manifest?(@payload, manifest_key)

      entries = {}
      fs = CorpusFs.new(root: Rails.configuration.x.corpus_root)

      @manifest.documents.each do |doc|
        text = body_for(doc, fs)
        count = SearchText.count(text, @term)
        next unless count.positive?

        entries[doc["id"]] = {
          "fingerprint" => doc["fingerprint"],
          "count" => count
        }
      rescue Errno::ENOENT, Errno::EACCES, Errno::EIO, SecurityError, Encoding::CompatibilityError
        next
      end

      @payload = self.class.fresh_payload_for(
        @term,
        manifest_fingerprint: manifest_key,
        total_documents: @manifest.documents.length
      )
      @payload["generated_at"] = Time.now.utc.iso8601
      @payload["entries"] = entries
      @cache_store.write_json(@cache_path, @payload)
      self
    end

    def doc_ids_with_hits
      refresh!
      @payload.fetch("entries", {}).keys
    end

    def count_for(doc_id)
      refresh!
      @payload.dig("entries", doc_id.to_s, "count").to_i
    end

    def self.fresh_payload_for(term, manifest_fingerprint: nil, total_documents: nil)
      {
        "version" => 2,
        "term" => term,
        "generated_at" => nil,
        "manifest_fingerprint" => manifest_fingerprint,
        "total_documents" => total_documents,
        "entries" => {}
      }
    end

    def self.current_for_manifest?(payload, manifest_fingerprint)
      payload.is_a?(Hash) &&
        payload["version"].to_i >= 2 &&
        payload["manifest_fingerprint"].to_s == manifest_fingerprint.to_s
    end

    def self.manifest_fingerprint(manifest)
      digest = Digest::SHA256.new
      manifest.documents.each do |doc|
        digest << doc["id"].to_s
        digest << "\0"
        digest << doc["fingerprint"].to_s
        digest << "\n"
      end
      digest.hexdigest
    end

    def self.body_for_doc(fs, doc)
      raw = fs.read_text(fs.resolve(doc["path"]))
      _metadata, body = FrontMatter.split(raw)
      body
    end
    private_class_method :body_for_doc

    private

    def body_for(doc, fs)
      self.class.send(:body_for_doc, fs, doc)
    end
  end
end
