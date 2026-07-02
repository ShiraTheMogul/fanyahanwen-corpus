# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "pathname"
require "time"
require "zip"

module CorpusSearch
  # Writes a complete prepared result and its compact R analysis hand-off.
  class ExportWriter
    RESULT_COLUMNS = %w[
      query mode query_text terms maximum_span order punctuation character_equivalence
      character_equivalence_version normalization_profile_version equivalence_matches
      snippet matched_text left_context right_context
      title work author date_text year_start year_end nation period region path folder_path
      document_role canonical_parent_path doc_id start_offset end_offset
      search_start_offset search_end_offset term_matches
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
        document_counts_csv = output_dir.join("document_counts.csv")
        analysis_dataset_json = output_dir.join("analysis_dataset.json")
        metadata_json = output_dir.join("metadata.json")
        readme_txt = output_dir.join("README.txt")
        analysis_dir = output_dir.join("analysis", "dataset_summary")
        zip_path = output_dir.join("corpus_search_#{@prepared_search.id}.zip")

        hit_count = write_streamed_csvs(result_csv, flashcard_csv, runner)

        @prepared_search.update!(progress: { "stage" => "building_analysis_dataset" })
        dataset_writer = AnalysisDatasetWriter.new(
          query: @query,
          manifest: manifest,
          cache_store: @cache_store
        )
        dataset_writer.write!(
          csv_path: document_counts_csv,
          metadata_path: analysis_dataset_json,
          progress: lambda do |files_scanned, files_total|
            next unless (files_scanned % 25).zero? || files_scanned == files_total

            @prepared_search.update!(
              progress: {
                "stage" => "building_analysis_dataset",
                "files_scanned" => files_scanned,
                "files_total" => files_total,
                "hits_found" => hit_count
              }
            )
          end
        )

        @prepared_search.update!(progress: { "stage" => "running_r" })
        r_result = RAnalysisRunner.new.run(
          profile: "dataset_summary",
          input_path: document_counts_csv,
          output_dir: analysis_dir
        )

        copy_r_readme(output_dir.join("analysis"))
        write_research_readme(readme_txt, r_result)
        write_metadata(
          metadata_json,
          hit_count,
          manifest: manifest,
          dataset_writer: dataset_writer,
          r_result: r_result
        )
        write_zip(zip_path, output_dir)

        @prepared_search.update!(
          status: "complete",
          progress: {
            "stage" => "complete",
            "hits_found" => hit_count
          },
          outputs: {
            "zip_path" => zip_path.to_s,
            "hit_count" => hit_count,
            "analysis_status" => r_result.status,
            "analysis_documents" => dataset_writer.document_count,
            "searchable_characters" => dataset_writer.searchable_character_count
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
        when "query_text"
          @query.exact? ? @query.query_text : nil
        when "terms"
          @query.multi_term? ? JSON.generate(@query.terms) : nil
        when "maximum_span"
          @query.proximity? ? @query.maximum_span : nil
        when "order"
          @query.proximity? ? @query.order : nil
        when "punctuation"
          @query.punctuation
        when "character_equivalence"
          @query.character_equivalence
        when "character_equivalence_version"
          @query.character_equivalence_version
        when "normalization_profile_version"
          @query.normalization_profile_version
        when "equivalence_matches"
          JSON.generate(hit["equivalence_matches"])
        when "term_matches"
          @query.multi_term? ? JSON.generate(hit["term_matches"]) : nil
        else
          hit[column]
        end
      end
    end

    def flashcard_row(hit)
      target = if @query.exact?
        @query.query_text
      elsif @query.alternatives?
        @query.terms.join(" OR ")
      else
        @query.terms.join(" · ")
      end
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

    def write_metadata(path, hit_count, manifest:, dataset_writer:, r_result:)
      metadata = {
        "generated_at" => Time.now.utc.iso8601,
        "query" => @query.to_h,
        "live_query_path" => @query.relative_url(include_presentation: false),
        "manifest_generated_at" => manifest.generated_at.to_s,
        "hit_count" => hit_count,
        "analysis_dataset" => {
          "body_only" => true,
          "documents" => dataset_writer.document_count,
          "searchable_characters" => dataset_writer.searchable_character_count,
          "occurrences" => dataset_writer.occurrence_count,
          "file" => "document_counts.csv"
        },
        "r_analysis" => {
          "profile" => r_result.profile,
          "status" => r_result.status,
          "r_version" => r_result.r_version,
          "duration_seconds" => r_result.duration_seconds,
          "directory" => "analysis/dataset_summary"
        },
        "columns" => {
          "results_csv" => RESULT_COLUMNS,
          "flashcards_csv" => FLASHCARD_COLUMNS,
          "document_counts_csv" => AnalysisDatasetWriter::COLUMNS
        },
        "equivalence_sources" => CharacterEquivalenceRegistry::OPENCC_DICTIONARIES.values
          .push("taiwan_moe", "zetian_script")
          .uniq
          .to_h { |source| [source, I18n.t("corpus_search.equivalence_sources.#{source}")] },
        "notes" => [
          I18n.t("corpus_search.export.metadata_notes.blank_years"),
          I18n.t("corpus_search.export.metadata_notes.offsets"),
          I18n.t("corpus_search.export.metadata_notes.equivalence"),
          I18n.t("corpus_search.export.metadata_notes.canonical_source"),
          I18n.t("corpus_search.export.metadata_notes.analysis_dataset")
        ]
      }

      path.write(JSON.pretty_generate(metadata))
    end

    def write_research_readme(path, r_result)
      path.write(<<~TEXT)
        Fanya Hanwen Corpus search export
        =================================

        Query: #{@query.display_label}
        Search mode: #{@query.mode}
        Character matching: #{@query.character_equivalence}
        Punctuation: #{@query.punctuation}
        R profile: #{r_result.profile}
        R status: #{r_result.status}
        R runtime: #{r_result.r_version || "unavailable"}

        Files
        -----
        results.csv              Occurrence-level concordance results.
        flashcards.csv           Compact flashcard export.
        document_counts.csv      Body-only document counts and denominators for R.
        analysis_dataset.json    Dataset provenance and query definition.
        metadata.json            Export-wide provenance.
        analysis/dataset_summary/analysis.R
                                 Exact application-owned R script used for this run.
        analysis/dataset_summary/summary.csv
                                 Overall R summary when R completed.
        analysis/dataset_summary/role_summary.csv
                                 R summary by corpus layer when R completed.
        analysis/dataset_summary/sessionInfo.txt
                                 Exact R runtime and loaded base packages.
        analysis/dataset_summary/run_metadata.json
                                 Timing, limits, command, and status.

        Metadata headers were not searched and are not included in searchable-character
        denominators. Descriptive metadata columns are labels attached to the corpus files.
      TEXT
    end

    def copy_r_readme(directory)
      source = Rails.root.join("analysis", "r", "README.md")
      return unless source.file?

      FileUtils.mkdir_p(directory)
      FileUtils.cp(source, directory.join("README.md"))
    end

    def write_zip(path, directory)
      FileUtils.rm_f(path)
      Zip::File.open(path, create: true) do |zip|
        Dir.glob(directory.join("**", "*"), File::FNM_DOTMATCH).sort.each do |entry|
          source = Pathname(entry)
          next unless source.file?
          next if source == path

          relative = source.relative_path_from(directory).to_s
          zip.add(relative, source.to_s)
        end
      end
    end
  end
end
