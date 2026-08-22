# frozen_string_literal: true

require "digest"

module CorpusSearch
  # Targeted manifest updates for the common case where a small number of TXT
  # bodies changed but metadata/authority semantics did not. Metadata changes
  # deliberately fall back to Manifest#refresh!, because compilation relations
  # can make one metadata.json affect rows outside its own directory.
  module ManifestIncrementalExtension
    def self.prepended(base)
      base.singleton_class.prepend(ClassMethods)
    end

    module ClassMethods
      def refresh_paths!(paths:, root: Rails.configuration.x.corpus_root, cache_store: CacheStore.new)
        new(root: root, cache_store: cache_store).refresh_paths!(paths)
      end
    end

    def refresh_paths!(relative_paths)
      cached = @cache_store.read_json(CACHE_PATH)
      raise CacheMissing, "Incremental manifest refresh requires a current full manifest cache." unless cache_current?(cached)

      documents = Array(cached["documents"]).map(&:dup)
      by_path = documents.index_by { |doc| doc["path"].to_s }
      changed = Array(relative_paths).map { |path| normalize_incremental_path(path) }.reject(&:blank?).uniq
      unless changed.all? { |path| path.downcase.end_with?(".txt") }
        raise ArgumentError, "Targeted manifest refresh accepts TXT paths only; metadata changes require a full incremental scan."
      end

      changed.each do |relative_path|
        by_path.delete(relative_path)
        absolute_path = File.join(@root, relative_path)
        next unless File.file?(absolute_path)

        stat = File.stat(absolute_path)
        metadata_path = @metadata_store.metadata_path_for(relative_path)
        fingerprint = fingerprint_for(stat, metadata_path)
        document = build_document(relative_path, absolute_path, stat, fingerprint)
        by_path[relative_path] = document if document && document["searchable_body"]
      end

      scanned = by_path.values.sort_by { |doc| doc["path"].to_s }
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
      progress("targeted manifest refresh complete: #{changed.length} changed TXT path(s); #{@documents.length} documents")
      self
    end

    private

    # Term counts depend on body bytes and document role, not metadata mtimes.
    # The old fingerprint included metadata.json in doc["fingerprint"], causing
    # a harmless chronology/author edit to invalidate every warmed term index.
    def term_index_fingerprint_for_documents(documents)
      digest = Digest::SHA256.new
      digest << "manifest-role-profile:canonical-body-v2\n"
      Array(documents).each do |doc|
        role = doc["document_role"].presence || "canonical"
        next unless DocumentRole.default?(role)

        digest << doc["id"].to_s << "\0"
        digest << (doc["body_fingerprint"].presence || doc["fingerprint"]).to_s << "\0"
        digest << role.to_s << "\n"
      end
      digest.hexdigest
    end

    def normalize_incremental_path(path)
      value = path.to_s.tr("\\", "/").sub(%r{\A/+}, "")
      corpus_prefix = begin
        Pathname(@root).relative_path_from(Rails.root.parent).to_s.tr("\\", "/")
      rescue ArgumentError
        ""
      end
      prefix = corpus_prefix.present? ? "#{corpus_prefix}/" : ""
      value = value.delete_prefix(prefix) if prefix.present? && value.start_with?(prefix)
      value
    end
  end
end
