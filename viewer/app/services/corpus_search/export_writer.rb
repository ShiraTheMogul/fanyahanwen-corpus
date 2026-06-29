# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "zip"
require "time"

module CorpusSearch
  # Writes a complete prepared search result as a mobile-friendly .zip.
  class ExportWriter
    RESULT_COLUMNS = %w[
      query mode term_a term_b distance order snippet matched_text left_context right_context
      title work author date_text year_start year_end nation period region path doc_id
      start_offset end_offset term_a_offset term_b_offset
    ].freeze

    FLASHCARD_COLUMNS = %w[front back target snippet source tags].freeze

    def initialize(prepared_search:, cache_store: CacheStore.new)
      @prepared_search = prepared_search
      @cache_store = cache_store
      @query = prepared_search.query
    end

    def write!
      I18n.with_locale(@prepared_search.locale) do
        @prepared_search.update!(status: "running", progress: { "stage" => "searching" })

        manifest = Manifest.load(cache_store: @cache_store)
        runner = Runner.new(query: @query, manifest: manifest, cache_store: @cache_store)

        output_dir = @prepared_search.output_dir
        result_csv = output_dir.join("results.csv")
        flashcard_csv = output_dir.join("flashcards.csv")
        metadata_json = output_dir.join("metadata.json")
        zip_path = output_dir.join("corpus_search_#{@prepared_search.id}.zip")

        hit_count = write_streamed_csvs(result_csv, flashcard_csv, runner)
        write_metadata(metadata_json, hit_count)
        write_zip(zip_path, result_csv, flashcard_csv, metadata_json)

        @prepared_search.update!(
          status: "complete",
          progress: {
            "stage" => "complete",
            "hits_found" => hit_count
          },
          outputs: {
            "zip_path" => zip_path.to_s,
            "hit_count" => hit_count
          }
        )

        zip_path
      end
    rescue StandardError => e
      @prepared_search.update!(status: "failed", progress: { "stage" => "failed" }, error_message: "#{e.class}: #{e.message}")
      raise
    end

    private

    def write_streamed_csvs(result_path, flashcard_path, runner)
      hit_count = 0

      CSV.open(result_path, "w", encoding: "UTF-8") do |results_csv|
        CSV.open(flashcard_path, "w", encoding: "UTF-8") do |flashcards_csv|
          results_csv << RESULT_COLUMNS
          flashcards_csv << FLASHCARD_COLUMNS

          progress = lambda do |files_scanned, files_total, hits_found|
            next unless (files_scanned % 25).zero? || files_scanned == files_total

            @prepared_search.update!(
              progress: {
                "stage" => "searching",
                "files_scanned" => files_scanned,
                "files_total" => files_total,
                "hits_found" => hits_found
              }
            )
          end

          runner.each_hit(progress: progress) do |hit|
            results_csv << result_row(hit)
            flashcards_csv << flashcard_row(hit)
            hit_count += 1
          end
        end
      end

      hit_count
    end

    def result_row(hit)
      RESULT_COLUMNS.map do |column|
        case column
        when "query"
          @query.display_label
        when "mode"
          @query.mode
        when "term_a"
          @query.term_a
        when "term_b"
          @query.term_b
        when "distance"
          @query.proximity? ? @query.distance : nil
        when "order"
          @query.proximity? ? @query.order : nil
        else
          hit[column]
        end
      end
    end

    def flashcard_row(hit)
      target = @query.term_a
      source = [hit["title"], hit["author"], hit["period"], hit["nation"], hit["path"]].reject(&:blank?).join(" | ")
      tags = ["corpus", tag_value("target", target), tag_value("period", hit["period"]), tag_value("nation", hit["nation"])].compact.join(" ")

      [
        I18n.t("corpus_search.export.flashcards.front", target: target, snippet: hit["snippet"]),
        I18n.t("corpus_search.export.flashcards.back", target: target, source: source),
        target,
        hit["snippet"],
        source,
        tags
      ]
    end

    def tag_value(prefix, value)
      clean = value.to_s.strip.gsub(/\s+/, "_")
      return nil if clean.empty?

      "#{prefix}::#{clean}"
    end

    def write_metadata(path, hit_count)
      metadata = {
        "generated_at" => Time.now.utc.iso8601,
        "query" => @query.to_h,
        "hit_count" => hit_count,
        "columns" => {
          "results_csv" => RESULT_COLUMNS,
          "flashcards_csv" => FLASHCARD_COLUMNS
        },
        "notes" => [
          I18n.t("corpus_search.export.metadata_notes.blank_years"),
          I18n.t("corpus_search.export.metadata_notes.offsets"),
          I18n.t("corpus_search.export.metadata_notes.canonical_source")
        ]
      }

      path.write(JSON.pretty_generate(metadata))
    end

    def write_zip(path, *files)
      FileUtils.rm_f(path)
      Zip::File.open(path, create: true) do |zip|
        files.each do |file|
          zip.add(File.basename(file), file.to_s)
        end
      end
    end
  end
end
