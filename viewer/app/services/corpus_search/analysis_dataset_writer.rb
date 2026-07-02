# frozen_string_literal: true

require "csv"
require "json"
require "pathname"
require "time"

module CorpusSearch
  # Writes the compact document-level table used by application-owned R
  # analyses. It contains counts and descriptive corpus metadata, never body
  # text or front-matter lines. Searchable-character denominators are measured
  # from DocumentReader.body using the query's punctuation policy.
  class AnalysisDatasetWriter
    COLUMNS = %w[
      doc_id path folder_path document_role title work author date_text
      year_start year_end nation period region searchable_characters
      occurrences matching_document matched_terms_json
    ].freeze

    attr_reader :document_count, :occurrence_count, :searchable_character_count

    def initialize(query:, manifest:, cache_store: CacheStore.new)
      @query = query
      @manifest = manifest
      @cache_store = cache_store
      @document_count = 0
      @occurrence_count = 0
      @searchable_character_count = 0
    end

    def write!(csv_path:, metadata_path: nil, progress: nil)
      @document_count = 0
      @occurrence_count = 0
      @searchable_character_count = 0
      runner = Runner.new(query: @query, manifest: @manifest, cache_store: @cache_store)

      CSV.open(csv_path, "w", encoding: "UTF-8", write_headers: true, headers: COLUMNS) do |csv|
        runner.each_analysis_document(progress: progress) do |record|
          doc = record.document
          hits = record.hits
          searchable_characters = record.searchable_characters.to_i

          @document_count += 1
          @occurrence_count += hits.length
          @searchable_character_count += searchable_characters

          csv << {
            "doc_id" => doc["id"],
            "path" => doc["path"],
            "folder_path" => doc["folder_path"],
            "document_role" => doc["document_role"].presence || "canonical",
            "title" => doc["title"],
            "work" => doc["work"],
            "author" => doc["author"],
            "date_text" => doc["date_text"],
            "year_start" => doc["year_start"],
            "year_end" => doc["year_end"],
            "nation" => doc["nation"],
            "period" => doc["period"],
            "region" => doc["region"],
            "searchable_characters" => searchable_characters,
            "occurrences" => hits.length,
            "matching_document" => hits.any? ? 1 : 0,
            "matched_terms_json" => JSON.generate(matched_terms(hits))
          }
        end
      end

      write_metadata(metadata_path) if metadata_path
      csv_path
    end

    private

    def matched_terms(hits)
      if @query.exact?
        hits.any? ? [@query.query_text] : []
      else
        hits.flat_map { |hit| Array(hit["term_matches"]).map { |match| match["term"].to_s } }
          .reject(&:empty?)
          .uniq
      end
    end

    def write_metadata(path)
      payload = {
        "version" => 1,
        "generated_at" => Time.now.utc.iso8601,
        "manifest_generated_at" => @manifest.generated_at.to_s,
        "query" => @query.to_h,
        "body_only" => true,
        "punctuation" => @query.punctuation,
        "document_count" => @document_count,
        "occurrence_count" => @occurrence_count,
        "searchable_character_count" => @searchable_character_count,
        "columns" => COLUMNS
      }
      Pathname(path).write(JSON.pretty_generate(payload))
    end
  end
end
