# frozen_string_literal: true

require "digest"
require "set"
require "time"

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

    # Efficient warmer for many single-character terms.
    #
    # The first implementation kept one full payload per term in memory and also
    # stored zero-count entries. With a 491k-file corpus, LIMIT=200 could create
    # tens of millions of Ruby hashes before anything was written. Linux then
    # killed the process without a Ruby traceback.
    #
    # This version is deliberately boring and memory-safe:
    #   * process terms in small batches
    #   * read each file once per batch
    #   * store only positive counts
    #   * write each term index after each batch
    def self.refresh_single_character_terms!(terms:, manifest:, cache_store: CacheStore.new, progress: nil, batch_size: nil, force: false)
      terms = terms.map(&:to_s).map(&:strip).select { |term| term.each_char.count == 1 }.uniq
      return 0 if terms.empty?

      batch_size = Integer(batch_size || ENV.fetch("CORPUS_SEARCH_TERM_BATCH_SIZE", DEFAULT_BATCH_SIZE))
      batch_size = DEFAULT_BATCH_SIZE if batch_size <= 0

      manifest_key = manifest_fingerprint(manifest)
      total_documents = manifest.documents.length
      batches = terms.each_slice(batch_size).to_a
      total_file_passes = total_documents * batches.length

      fs = CorpusFs.new(root: Rails.configuration.x.corpus_root)
      file_passes_read = 0
      file_passes_skipped = 0

      batches.each_with_index do |batch_terms, batch_index|
        batch_set = batch_terms.to_set
        payloads = batch_terms.to_h do |term|
          if !force
            existing = cache_store.read_json(cache_path_for(term))
            if current_for_manifest?(existing, manifest_key)
              next [term, existing]
            end
          end

          [term, fresh_payload_for(term, manifest_fingerprint: manifest_key, total_documents: total_documents)]
        end

        # If every term in this batch is already current, there is nothing to scan.
        next if payloads.values.all? { |payload| current_for_manifest?(payload, manifest_key) && payload["generated_at"].present? }

        scan_offset = batch_index * total_documents

        manifest.documents.each_with_index do |doc, index|
          body = body_for_doc(fs, doc)
          counts = Hash.new(0)
          body.each_char { |char| counts[char] += 1 if batch_set.include?(char) }

          batch_terms.each do |term|
            count = counts[term].to_i
            next unless count.positive?

            payloads[term]["entries"][doc["id"]] = {
              "fingerprint" => doc["fingerprint"],
              "count" => count
            }
          end

          file_passes_read += 1
          progress&.call(scan_offset + index + 1, total_file_passes, file_passes_read, file_passes_skipped)
        rescue Errno::ENOENT, Errno::EACCES, Errno::EIO, SecurityError, Encoding::CompatibilityError => e
          file_passes_skipped += 1
          progress&.call(scan_offset + index + 1, total_file_passes, file_passes_read, file_passes_skipped, e)
          next
        end

        generated_at = Time.now.utc.iso8601
        payloads.each do |term, payload|
          payload["version"] = 2
          payload["generated_at"] = generated_at
          payload["manifest_fingerprint"] = manifest_key
          payload["total_documents"] = total_documents
          cache_store.write_json(cache_path_for(term), payload)
        end
      end

      terms.length
    end

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
