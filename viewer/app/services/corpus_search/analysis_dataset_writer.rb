# frozen_string_literal: true

require "csv"
require "json"
require "pathname"
require "time"

module CorpusSearch
  # Produces the compact body-only document table consumed by the Ruby analysis profile. The same
  # traversal can also stream occurrence rows, so a prepared analysis does not
  # scan the corpus once for results and then a second time for denominators.
  class AnalysisDatasetWriter
    COLUMNS = %w[
      doc_id document_id work_id body_fingerprint path folder_path document_role canonical_parent_path
      title work author date_text year_start year_end nation corpus_root macro_region polity period region searchable_characters
      occurrences matching_document matched_terms_json
    ].freeze

    attr_reader :document_count, :occurrence_count, :searchable_character_count

    def initialize(query:, manifest:, cache_store: CacheStore.new)
      @query = query
      @manifest = manifest
      @cache_store = cache_store
      reset_counters!
    end

    # Yields [document_row, hits] once for every document in scope. Hits are
    # already sorted and body offsets are already mapped to the original text.
    def each_document(progress: nil)
      reset_counters!
      runner = Runner.new(query: @query, manifest: @manifest, cache_store: @cache_store)

      runner.each_analysis_document(progress: progress) do |record|
        row = row_for(record)
        update_counters!(row)
        yield row, record.hits if block_given?
      end

      @document_count
    end

    def write!(csv_path:, metadata_path: nil, progress: nil)
      CSV.open(csv_path, "w", encoding: "UTF-8", write_headers: true, headers: COLUMNS) do |csv|
        each_document(progress: progress) do |row, _hits|
          csv << row
        end
      end

      write_metadata!(metadata_path) if metadata_path
      csv_path
    end

    def write_metadata!(path)
      payload = {
        "version" => 5,
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

    private

    def row_for(record)
      doc = record.document
      hits = record.hits
      searchable_characters = record.searchable_characters.to_i

      {
        "doc_id" => doc["id"],
        "document_id" => doc["id"],
        "work_id" => doc["work_id"],
        "body_fingerprint" => record.body_fingerprint,
        "path" => doc["path"],
        "folder_path" => doc["folder_path"],
        "document_role" => doc["document_role"].presence || "canonical",
        "canonical_parent_path" => doc["canonical_parent_path"],
        "title" => doc["title"],
        "work" => doc["work"],
        "author" => doc["author"],
        "date_text" => doc["date_text"],
        "year_start" => doc["year_start"],
        "year_end" => doc["year_end"],
        "nation" => doc["nation"],
        "corpus_root" => doc["corpus_root"],
        "macro_region" => doc["macro_region"],
        "polity" => doc["polity"],
        "period" => doc["period"],
        "region" => doc["region"],
        "searchable_characters" => searchable_characters,
        "occurrences" => hits.length,
        "matching_document" => hits.any? ? 1 : 0,
        "matched_terms_json" => JSON.generate(matched_terms(hits))
      }
    end

    def update_counters!(row)
      @document_count += 1
      @occurrence_count += row.fetch("occurrences").to_i
      @searchable_character_count += row.fetch("searchable_characters").to_i
    end

    def reset_counters!
      @document_count = 0
      @occurrence_count = 0
      @searchable_character_count = 0
    end

    def matched_terms(hits)
      if @query.exact?
        hits.any? ? [@query.query_text] : []
      else
        hits.flat_map { |hit| Array(hit["term_matches"]).map { |match| match["term"].to_s } }
          .reject(&:empty?)
          .uniq
      end
    end
  end
end
