# frozen_string_literal: true

require "digest"

module CorpusSearch
  # Carries authority-derived chronology and compilation metadata into the
  # rebuildable manifest without changing the existing search implementation.
  module ManifestHistoricalExtension
    EXTRA_QUERY_FIELDS = %w[
      category categories
      date_resolution_source date_resolution_confidence
      date_resolution_authority_kind date_resolution_authority_id
      date_resolution_authority_name date_resolution_country
      compilation_work_id compilation_title compilation_date_text
      compilation_year_start compilation_year_end compilation_period
      compilation_polity compilation_categories compilation_metadata_path
      compilation_date_resolution_source compilation_date_resolution_confidence
    ].freeze

    def build_document(relative_path, absolute_path, stat, fingerprint)
      document = super
      metadata = @metadata_store.search_metadata_for_path(relative_path)
      EXTRA_QUERY_FIELDS.each do |field|
        document[field] = metadata[field] if metadata.key?(field)
      end
      document
    end

    def compact_query_document(doc)
      output = super
      EXTRA_QUERY_FIELDS.each do |field|
        output[field] = doc[field] if doc.key?(field)
      end
      output
    end

    private

    def fingerprint_for(stat, metadata_path = nil)
      base = super
      dependencies = if @metadata_store.respond_to?(:metadata_dependency_paths_for_metadata_path)
        @metadata_store.metadata_dependency_paths_for_metadata_path(metadata_path)
      else
        Array(metadata_path)
      end

      dependency_fingerprint = dependencies.filter_map do |path|
        next unless path && File.file?(path)

        item = File.stat(path)
        "#{path}:#{item.size}:#{item.mtime.to_f}"
      end.join("|")

      authority = historical_resolution_candidate_metadata?(metadata_path) ? historical_authority_fingerprint : ""
      [base, dependency_fingerprint, authority].join(":")
    end

    def historical_resolution_candidate_metadata?(metadata_path)
      return false unless metadata_path && File.file?(metadata_path)

      metadata = @metadata_store.send(:read_json, Pathname(metadata_path))
      date_labels = [metadata["date_label"]]
      %w[documents editions translations].each do |collection|
        Array(metadata[collection]).each do |entry|
          next unless entry.is_a?(Hash)

          date_labels << entry["date_label"]
          Array(entry["documents"]).each do |document|
            date_labels << document["date_label"] if document.is_a?(Hash)
          end
        end
      end
      date_labels.compact.any? { |value| plausible_historical_year_text?(value.to_s) }
    rescue StandardError
      false
    end

    def plausible_historical_year_text?(value)
      value.match?(/\p{Han}{1,16}\s*(?:元|[〇零○一二三四五六七八九十百千廿卅卌兩两0-9]+)\s*年/)
    end

    def historical_authority_fingerprint
      return @historical_authority_fingerprint if defined?(@historical_authority_fingerprint)

      metadata = HistoricalAuthorityStore.default.metadata
      @historical_authority_fingerprint = Digest::SHA256.hexdigest(
        [metadata["cbdb_sha256"], metadata["historical_fingerprint"], metadata["equivalence_version"]]
          .map(&:to_s).join("\0")
      )
    rescue StandardError
      @historical_authority_fingerprint = "authority-unavailable"
    end
  end
end
