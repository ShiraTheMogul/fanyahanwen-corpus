# frozen_string_literal: true

require "set"
require "time"

module CorpusSearch
  # On-demand index for one literal search term.
  #
  # It stores counts per file, not corpus text. It lets a query skip files that
  # cannot possibly match.
  class TermIndex
    def self.cache_path_for(term)
      File.join("term_indexes", "#{CacheStore.hash_key(term)}.json.gz")
    end

    # Efficient warmer for many single-character terms.
    #
    # The old naive shape was:
    #   for every term, read every file
    #
    # This shape is:
    #   for every file, read it once and count all selected characters
    def self.refresh_single_character_terms!(terms:, manifest:, cache_store: CacheStore.new, progress: nil)
      terms = terms.map(&:to_s).map(&:strip).select { |term| term.each_char.count == 1 }.uniq
      return 0 if terms.empty?

      term_set = terms.to_set
      payloads = terms.to_h do |term|
        existing = cache_store.read_json(cache_path_for(term))
        [term, existing || fresh_payload_for(term)]
      end

      current_ids = manifest.documents.map { |doc| doc["id"] }.to_set
      payloads.each_value do |payload|
        entries = payload["entries"] ||= {}
        entries.keys.each { |doc_id| entries.delete(doc_id) unless current_ids.include?(doc_id) }
      end

      fs = CorpusFs.new(root: Rails.configuration.x.corpus_root)
      files_read = 0
      files_skipped = 0

      manifest.documents.each_with_index do |doc, index|
        needs_update = terms.any? do |term|
          entry = payloads.dig(term, "entries", doc["id"])
          !entry || entry["fingerprint"] != doc["fingerprint"]
        end
        next unless needs_update

        body = body_for_doc(fs, doc)
        counts = Hash.new(0)
        body.each_char { |char| counts[char] += 1 if term_set.include?(char) }

        terms.each do |term|
          payloads[term]["entries"][doc["id"]] = {
            "fingerprint" => doc["fingerprint"],
            "count" => counts[term].to_i
          }
        end

        files_read += 1
        progress&.call(index + 1, manifest.documents.length, files_read, files_skipped)
      rescue Errno::ENOENT, Errno::EACCES, Errno::EIO, SecurityError, Encoding::CompatibilityError => e
        files_skipped += 1
        progress&.call(index + 1, manifest.documents.length, files_read, files_skipped, e)
        terms.each { |term| payloads[term]["entries"].delete(doc["id"]) }
        next
      end

      generated_at = Time.now.utc.iso8601
      payloads.each do |term, payload|
        payload["generated_at"] = generated_at
        cache_store.write_json(cache_path_for(term), payload)
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
      entries = @payload["entries"] ||= {}
      changed = false
      fs = CorpusFs.new(root: Rails.configuration.x.corpus_root)

      @manifest.documents.each do |doc|
        cached = entries[doc["id"]]
        next if cached && cached["fingerprint"] == doc["fingerprint"]

        text = body_for(doc, fs)
        entries[doc["id"]] = {
          "fingerprint" => doc["fingerprint"],
          "count" => SearchText.count(text, @term)
        }
        changed = true
      rescue Errno::ENOENT, Errno::EACCES, Errno::EIO, SecurityError, Encoding::CompatibilityError
        changed ||= entries.key?(doc["id"])
        entries.delete(doc["id"])
      end

      current_ids = @manifest.documents.map { |doc| doc["id"] }.to_set
      entries.keys.each do |doc_id|
        next if current_ids.include?(doc_id)

        entries.delete(doc_id)
        changed = true
      end

      if changed || @payload["generated_at"].blank?
        @payload["generated_at"] = Time.now.utc.iso8601
        @cache_store.write_json(@cache_path, @payload)
      end
      self
    end

    def doc_ids_with_hits
      refresh!
      @payload.fetch("entries", {}).filter_map do |doc_id, entry|
        doc_id if entry["count"].to_i.positive?
      end
    end

    def count_for(doc_id)
      refresh!
      @payload.dig("entries", doc_id.to_s, "count").to_i
    end

    def self.fresh_payload_for(term)
      {
        "version" => 1,
        "term" => term,
        "generated_at" => nil,
        "entries" => {}
      }
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
