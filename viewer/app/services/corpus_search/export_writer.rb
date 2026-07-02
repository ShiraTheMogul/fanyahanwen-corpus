# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "pathname"
require "time"
require "zip"

module CorpusSearch
  # Writes a complete prepared result plus the body-only tables consumed by the
  # fixed R analysis profile. Metadata may label rows but never contributes to
  # matching, snippets, occurrence counts, or searchable-character denominators.
  class ExportWriter
    RESULT_COLUMNS = %w[
      occurrence_id query mode query_text terms maximum_span order punctuation
      character_equivalence character_equivalence_version normalization_profile_version
      proximity_span matched_term_order matched_alternatives equivalence_matches
      snippet matched_text left_context right_context
      title work author date_text year_start year_end nation period region path folder_path
      document_role canonical_parent_path doc_id start_offset end_offset
      search_start_offset search_end_offset term_matches
    ].freeze

    FLASHCARD_COLUMNS = %w[front back target snippet source tags].freeze
    ANALYSIS_OCCURRENCE_COLUMNS = %w[
      occurrence_id doc_id path mode search_start_offset search_end_offset
      proximity_span matched_term_order matched_alternatives
    ].freeze

    def initialize(prepared_search:, cache_store: CacheStore.new)
      @prepared_search = prepared_search
      @cache_store = cache_store
      @query = prepared_search.query
    end

    def write!
      I18n.with_locale(@prepared_search.locale) do
        @prepared_search.update!(status: "running", progress: { "stage" => "searching" })

        manifest = Manifest.load(cache_store: @cache_store)

        output_dir = @prepared_search.output_dir
        result_csv = output_dir.join("results.csv")
        flashcard_csv = output_dir.join("flashcards.csv")
        document_counts_csv = output_dir.join("document_counts.csv")
        analysis_occurrences_csv = output_dir.join("analysis_occurrences.csv")
        analysis_dataset_json = output_dir.join("analysis_dataset.json")
        metadata_json = output_dir.join("metadata.json")
        readme_txt = output_dir.join("README.txt")
        analysis_dir = output_dir.join("analysis", "standard")
        zip_path = output_dir.join("corpus_search_#{@prepared_search.id}.zip")

        dataset_writer = AnalysisDatasetWriter.new(
          query: @query,
          manifest: manifest,
          cache_store: @cache_store
        )
        hit_count = write_streamed_datasets(
          result_csv,
          flashcard_csv,
          document_counts_csv,
          analysis_occurrences_csv,
          dataset_writer
        )
        dataset_writer.write_metadata!(analysis_dataset_json)

        @prepared_search.update!(progress: { "stage" => "running_r" })
        r_result = RAnalysisRunner.new.run(
          profile: "standard_analysis",
          document_counts_path: document_counts_csv,
          occurrences_path: analysis_occurrences_csv,
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
            "analysis_profile" => r_result.profile,
            "analysis_report_path" => analysis_dir.join("analysis_report.json").to_s,
            "analysis_documents" => dataset_writer.document_count,
            "matching_documents" => analysis_overall(analysis_dir)["matching_documents"],
            "searchable_characters" => dataset_writer.searchable_character_count,
            "occurrences_per_million" => analysis_overall(analysis_dir)["occurrences_per_million"],
            "document_prevalence" => analysis_overall(analysis_dir)["document_prevalence"]
          }
        )

        zip_path
      end
    rescue StandardError => e
      @prepared_search.update!(status: "failed", progress: { "stage" => "failed" }, error_message: "#{e.class}: #{e.message}")
      raise
    end

    private

    def write_streamed_datasets(result_path, flashcard_path, document_path, occurrence_path, dataset_writer)
      hit_count = 0

      CSV.open(result_path, "w", encoding: "UTF-8") do |results_csv|
        CSV.open(flashcard_path, "w", encoding: "UTF-8") do |flashcards_csv|
          CSV.open(document_path, "w", encoding: "UTF-8", write_headers: true, headers: AnalysisDatasetWriter::COLUMNS) do |documents_csv|
            CSV.open(occurrence_path, "w", encoding: "UTF-8", write_headers: true, headers: ANALYSIS_OCCURRENCE_COLUMNS) do |occurrences_csv|
              results_csv << RESULT_COLUMNS
              flashcards_csv << FLASHCARD_COLUMNS

              progress = lambda do |files_scanned, files_total|
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

              dataset_writer.each_document(progress: progress) do |document_row, hits|
                documents_csv << document_row
                hits.each do |hit|
                  hit_count += 1
                  results_csv << result_row(hit, occurrence_id: hit_count)
                  occurrences_csv << analysis_occurrence_row(hit, occurrence_id: hit_count)
                  flashcards_csv << flashcard_row(hit)
                end
              end
            end
          end
        end
      end

      hit_count
    end

    def analysis_occurrence_row(hit, occurrence_id:)
      {
        "occurrence_id" => occurrence_id,
        "doc_id" => hit["doc_id"],
        "path" => hit["path"],
        "mode" => @query.mode,
        "search_start_offset" => hit["search_start_offset"],
        "search_end_offset" => hit["search_end_offset"],
        "proximity_span" => @query.proximity? ? hit["search_end_offset"].to_i - hit["search_start_offset"].to_i : nil,
        "matched_term_order" => matched_term_order(hit),
        "matched_alternatives" => @query.alternatives? ? matched_alternatives(hit).join(" | ") : nil
      }
    end

    def result_row(hit, occurrence_id:)
      RESULT_COLUMNS.map do |column|
        case column
        when "occurrence_id"
          occurrence_id
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
        when "proximity_span"
          @query.proximity? ? hit["search_end_offset"].to_i - hit["search_start_offset"].to_i : nil
        when "matched_term_order"
          matched_term_order(hit)
        when "matched_alternatives"
          @query.alternatives? ? matched_alternatives(hit).join(" | ") : nil
        when "equivalence_matches"
          JSON.generate(hit["equivalence_matches"])
        when "term_matches"
          @query.multi_term? ? JSON.generate(hit["term_matches"]) : nil
        else
          hit[column]
        end
      end
    end

    def matched_term_order(hit)
      return nil unless @query.multi_term?

      Array(hit["term_matches"])
        .sort_by { |match| [match["search_start_offset"].to_i, match["term_index"].to_i] }
        .map { |match| match["term"].to_s }
        .reject(&:blank?)
        .join(" > ")
    end

    def matched_alternatives(hit)
      Array(hit["term_matches"])
        .sort_by { |match| match["term_index"].to_i }
        .map { |match| match["term"].to_s }
        .reject(&:blank?)
        .uniq
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

    def analysis_overall(directory)
      report = AnalysisReport.load(directory)
      report ? report.overall : {}
    end

    def write_metadata(path, hit_count, manifest:, dataset_writer:, r_result:)
      metadata = {
        "version" => 7,
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
          "file" => "document_counts.csv",
          "occurrence_file" => "analysis_occurrences.csv"
        },
        "r_analysis" => {
          "profile" => r_result.profile,
          "status" => r_result.status,
          "r_version" => r_result.r_version,
          "duration_seconds" => r_result.duration_seconds,
          "directory" => "analysis/standard",
          "report" => "analysis/standard/analysis_report.json"
        },
        "columns" => {
          "results_csv" => RESULT_COLUMNS,
          "flashcards_csv" => FLASHCARD_COLUMNS,
          "document_counts_csv" => AnalysisDatasetWriter::COLUMNS,
          "analysis_occurrences_csv" => ANALYSIS_OCCURRENCE_COLUMNS
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
        Fanya Hanwen Corpus search and analysis export
        ===============================================

        Query: #{@query.display_label}
        Search mode: #{@query.mode}
        Character matching: #{@query.character_equivalence}
        Punctuation: #{@query.punctuation}
        R profile: #{r_result.profile}
        R status: #{r_result.status}
        R runtime: #{r_result.r_version || "unavailable"}

        Core files
        ----------
        results.csv              One row per matched occurrence.
        flashcards.csv           Compact flashcard export.
        document_counts.csv      One body-only row per document in scope,
                                 including documents with zero matches.
        analysis_occurrences.csv Compact occurrence offsets used by R. It omits
                                 snippets and repeated descriptive metadata.
        analysis_dataset.json    Dataset provenance and query definition.
        metadata.json            Export-wide provenance.

        Standard R analysis
        -------------------
        analysis/standard/analysis.R
                                 Exact application-owned R script used.
        analysis/standard/analysis_report.json
                                 Machine-readable summary and chart manifest.
        analysis/standard/*_summary.csv
                                 Complete grouped tables for period, nation,
                                 region, author, folder branch, and corpus layer.
        analysis/standard/top_documents.csv
                                 Documents contributing the largest hit counts.
        analysis/standard/matches_per_document.csv
                                 Distribution of occurrences across documents.
        analysis/standard/proximity_spans.csv
                                 Occurrence-level spans for proximity searches.
        analysis/standard/figures/*.svg
                                 Scalable browser and publication figures.
        analysis/standard/figures/*.png
                                 Raster copies suitable for slides.
        analysis/standard/sessionInfo.txt
                                 Exact R runtime and loaded base packages.
        analysis/standard/run_metadata.json
                                 Timing, limits, command, inputs, and status.

        Metadata headers were not searched and are not included in searchable-
        character denominators. Descriptive metadata columns only label corpus
        documents and analytical groups.
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
