# frozen_string_literal: true

require "csv"
require "digest"
require "erb"
require "fileutils"
require "json"
require "pathname"
require "time"
require "zip"

module CorpusSearch
  # Writes a complete prepared result plus the body-only tables consumed by the
  # fixed Ruby analysis profile. Metadata may label rows but never contributes to
  # matching, snippets, occurrence counts, or searchable-character denominators.
  class ExportWriter
    EXPORT_SCHEMA_VERSION = 7
    RESULT_COLUMNS = %w[
      occurrence_id query mode query_text terms maximum_span order punctuation
      character_equivalence character_equivalence_version normalization_profile_version
      proximity_span matched_term_order matched_alternatives equivalence_matches
      snippet matched_text left_context right_context
      title work author date_text year_start year_end nation corpus_root macro_region polity period region
      path source_url occurrence_key folder_path document_role canonical_parent_path doc_id document_id work_id start_offset end_offset
      search_start_offset search_end_offset term_matches
    ].freeze

    FLASHCARD_COLUMNS = %w[front back target snippet source tags].freeze
    ANALYSIS_OCCURRENCE_COLUMNS = %w[
      occurrence_id occurrence_key doc_id document_id work_id path source_url mode search_start_offset search_end_offset
      proximity_span matched_term_order matched_alternatives matched_forms
      left_neighbours right_neighbours
    ].freeze

    def initialize(prepared_search:, cache_store: CacheStore.new)
      @prepared_search = prepared_search
      @cache_store = cache_store
      @query = prepared_search.query
    end

    def write!
      @prepared_search.load!
      raise CancelledSearch, "Search was cancelled before it started" if @prepared_search.cancel_requested?

      existing_zip = @prepared_search.zip_path
      if @prepared_search.complete?
        return existing_zip if existing_zip&.file?

        raise ArgumentError, "Frozen prepared analysis is complete but its ZIP is missing"
      end

      I18n.with_locale(@prepared_search.locale) do
        total_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        stage_timings = {}
        source_prepared = @prepared_search.source_prepared
        @prepared_search.update!(
          status: "running",
          progress: { "stage" => source_prepared ? "copying_source_dataset" : "searching" }
        )

        output_dir = @prepared_search.output_dir
        FileUtils.rm_rf(output_dir)
        FileUtils.mkdir_p(output_dir)

        result_csv = output_dir.join("results.csv")
        flashcard_csv = output_dir.join("flashcards.csv")
        document_counts_csv = output_dir.join("document_counts.csv")
        analysis_occurrences_csv = output_dir.join("analysis_occurrences.csv")
        analysis_dataset_json = output_dir.join("analysis_dataset.json")
        query_json = output_dir.join("query.json")
        query_urls_txt = output_dir.join("query_urls.txt")
        corpus_snapshot_json = output_dir.join("corpus_snapshot.json")
        rerun_txt = output_dir.join("RERUN_ANALYSIS.txt")
        metadata_json = output_dir.join("metadata.json")
        readme_txt = output_dir.join("README.txt")
        methods_md = output_dir.join("METHODS.md")
        methods_txt = output_dir.join("METHODS.txt")
        citation_txt = output_dir.join("CITATION.txt")
        analysis_dir = output_dir.join("analysis", "standard")
        comparison_csv = output_dir.join("comparison.csv")
        research_manifest_json = output_dir.join("research_manifest.json")
        checksums_path = output_dir.join("checksums.sha256")
        zip_path = output_dir.join("corpus_search_#{@prepared_search.id}.zip")

        dataset_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if source_prepared
          copy_source_datasets!(source_prepared, output_dir)
          dataset_stats = dataset_stats_from(document_counts_csv)
          corpus_snapshot = source_corpus_snapshot(source_prepared)
        else
          manifest = Manifest.new(root: Rails.configuration.x.corpus_root, cache_store: @cache_store).load_cached!
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
          dataset_stats = {
            "documents" => dataset_writer.document_count,
            "occurrences" => hit_count,
            "searchable_characters" => dataset_writer.searchable_character_count
          }
          corpus_snapshot = corpus_snapshot_for(manifest)
        end
        stage_timings["dataset_seconds"] = elapsed_stage(dataset_started)

        corpus_snapshot = corpus_snapshot.merge(
          "selected_scope" => scope_totals_by_role(document_counts_csv),
          "search_definition_schema" => SearchDefinition::SCHEMA_VERSION,
          "query_cache_version" => QueryCache::VERSION,
          "export_schema_version" => EXPORT_SCHEMA_VERSION,
          "normalization_profile_version" => @query.normalization_profile_version,
          "character_equivalence_version" => @query.character_equivalence_version
        )
        write_query_json(query_json)
        write_query_urls(query_urls_txt)
        corpus_snapshot_json.write(JSON.pretty_generate(corpus_snapshot))

        comparison_path = write_comparison_csv(comparison_csv)
        write_rerun_instructions(rerun_txt, comparison: comparison_path.present?)
        @prepared_search.update!(progress: { "stage" => "running_analysis", "hits_found" => dataset_stats["occurrences"] })
        analysis_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        analysis_result = AnalysisRunner.new.run(
          profile: "standard_analysis",
          document_counts_path: document_counts_csv,
          occurrences_path: analysis_occurrences_csv,
          output_dir: analysis_dir,
          comparison_path: comparison_path
        )
        stage_timings["analysis_seconds"] = elapsed_stage(analysis_started)

        packaging_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        copy_analysis_readme(output_dir.join("analysis"))
        write_research_readme(readme_txt, analysis_result, corpus_snapshot: corpus_snapshot)
        write_metadata(
          metadata_json,
          dataset_stats["occurrences"],
          corpus_snapshot: corpus_snapshot,
          dataset_stats: dataset_stats,
          analysis_result: analysis_result
        )
        write_methods(methods_md, methods_txt, analysis_result, corpus_snapshot: corpus_snapshot, analysis_dir: analysis_dir)
        write_citation(citation_txt, corpus_snapshot: corpus_snapshot)
        write_research_manifest(research_manifest_json, output_dir, corpus_snapshot: corpus_snapshot)
        write_checksums(checksums_path, output_dir)
        write_zip(zip_path, output_dir)
        stage_timings["packaging_seconds"] = elapsed_stage(packaging_started)
        stage_timings["total_seconds"] = elapsed_stage(total_started)

        overall = analysis_overall(analysis_dir)
        outputs = {
          "zip_path" => zip_path.to_s,
          "hit_count" => dataset_stats["occurrences"],
          "analysis_status" => analysis_result.status,
          "analysis_profile" => analysis_result.profile,
          "analysis_report_path" => analysis_dir.join("analysis_report.json").to_s,
          "analysis_documents" => dataset_stats["documents"],
          "matching_documents" => overall["matching_documents"],
          "searchable_characters" => dataset_stats["searchable_characters"],
          "occurrences_per_million" => overall["occurrences_per_million"],
          "document_prevalence" => overall["document_prevalence"],
          "comparison" => @prepared_search.comparison&.to_h,
          "source_prepared_id" => source_prepared&.id,
          "snapshot_id" => corpus_snapshot["snapshot_id"],
          "stage_timings" => stage_timings,
          "documents_per_second" => stage_timings["dataset_seconds"].to_f.positive? ? (dataset_stats["documents"].to_f / stage_timings["dataset_seconds"]).round(2) : nil
        }
        artifacts = artifact_rows(output_dir, include_zip: true)

        @prepared_search.complete!(
          progress: { "hits_found" => dataset_stats["occurrences"] },
          outputs: outputs,
          corpus_snapshot: corpus_snapshot,
          artifact_manifest: artifacts
        )
        send_completion_notification

        zip_path
      end
    rescue CancelledSearch => e
      @prepared_search.cancel!(message: e.message)
      nil
    rescue StandardError => e
      @prepared_search.update!(status: "failed", progress: { "stage" => "failed" }, error_message: "#{e.class}: #{e.message}")
      raise
    end

    private

    def elapsed_stage(started)
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(4)
    end

    class CancelledSearch < StandardError; end

    def check_cancelled!
      @prepared_search.load!
      raise CancelledSearch, "Search was cancelled by request" if @prepared_search.cancel_requested?
    end

    def send_completion_notification
      return unless @prepared_search.full_search? && @prepared_search.notification_pending?

      email = @prepared_search.notification_email
      return if email.blank?

      CorpusSearchMailer.full_search_complete(
        email: email,
        prepared_search: @prepared_search,
        download_url: public_url("/corpus/search/prepared/#{@prepared_search.id}/download?key=#{ERB::Util.url_encode(@prepared_search.key)}"),
        expires_at: @prepared_search.payload["expires_at"]
      ).deliver_now
      @prepared_search.mark_notification_sent!
    rescue StandardError => e
      Rails.logger.warn("Corpus search completion email failed for #{@prepared_search.id}: #{e.class}: #{e.message}")
    end

    SOURCE_DATASET_FILES = %w[
      results.csv
      flashcards.csv
      document_counts.csv
      analysis_occurrences.csv
      analysis_dataset.json
    ].freeze

    def write_query_json(path)
      payload = {
        "version" => 2,
        "export_schema_version" => EXPORT_SCHEMA_VERSION,
        "prepared_record_id" => @prepared_search.id,
        "source_prepared_id" => @prepared_search.source_prepared_id,
        "query" => @query.to_h,
        "comparison" => @prepared_search.comparison&.to_h,
        "live_query_url" => public_url(@query.relative_url(include_presentation: false)),
        "frozen_result_url" => public_url(frozen_result_path)
      }
      path.write(JSON.pretty_generate(payload))
    end

    def write_query_urls(path)
      path.write(<<~TEXT)
        Source site base URL: #{public_base_url.presence || "(not configured; paths below are relative)"}
        Live query URL: #{public_url(@query.relative_url(include_presentation: false))}
        Frozen result URL: #{public_url(frozen_result_path)}
      TEXT
    end

    def write_rerun_instructions(path, comparison:)
      comparison_argument = comparison ? " comparison.csv" : ""
      path.write(<<~TEXT)
        Re-run the bundled standard analysis from the root of this extracted bundle:

        ruby analysis/standard/analysis.rb document_counts.csv analysis_occurrences.csv analysis/standard#{comparison_argument}

        The command overwrites the generated files inside analysis/standard. It does not
        read corpus files or metadata headers; it uses only the bundled body-only tables.
      TEXT
    end

    def scope_totals_by_role(document_counts_path)
      totals = Hash.new do |hash, role|
        hash[role] = {
          "documents" => 0,
          "matching_documents" => 0,
          "occurrences" => 0,
          "searchable_characters" => 0
        }
      end

      CSV.foreach(document_counts_path, headers: true, encoding: "bom|utf-8") do |row|
        role = row["document_role"].to_s.presence || "unknown"
        totals[role]["documents"] += 1
        totals[role]["matching_documents"] += 1 if row["matching_document"].to_i.positive?
        totals[role]["occurrences"] += row["occurrences"].to_i
        totals[role]["searchable_characters"] += row["searchable_characters"].to_i
      end

      {
        "documents" => totals.values.sum { |row| row["documents"] },
        "matching_documents" => totals.values.sum { |row| row["matching_documents"] },
        "occurrences" => totals.values.sum { |row| row["occurrences"] },
        "searchable_characters" => totals.values.sum { |row| row["searchable_characters"] },
        "by_document_role" => totals.sort.to_h
      }
    end

    def public_base_url
      configured = ENV.fetch("CORPUS_SEARCH_PUBLIC_BASE_URL", "").to_s.strip.sub(%r{/+\z}, "")
      return configured if configured.present?

      options = Rails.application.config.action_mailer.default_url_options.to_h.symbolize_keys
      host = options[:host].to_s.strip
      return "" if host.blank?

      protocol = options[:protocol].presence || (Rails.env.production? ? "https" : "http")
      port = options[:port].to_i
      default_port = (protocol == "https" ? 443 : 80)
      authority = port.positive? && port != default_port ? "#{host}:#{port}" : host
      "#{protocol}://#{authority}"
    end

    def public_url(path)
      base = public_base_url
      base.present? ? "#{base}#{path}" : path
    end

    def frozen_result_path
      key = ERB::Util.url_encode(@prepared_search.key)
      "/corpus/search/prepared/#{@prepared_search.id}?key=#{key}"
    end

    def copy_source_datasets!(source_prepared, output_dir)
      unless source_prepared.frozen?
        raise ArgumentError, "Source prepared analysis is not complete and frozen"
      end

      source_dir = source_prepared.output_dir
      SOURCE_DATASET_FILES.each do |filename|
        source = source_dir.join(filename)
        raise Errno::ENOENT, source.to_s unless source.file?

        FileUtils.cp(source, output_dir.join(filename))
      end
    end

    def dataset_stats_from(document_counts_path)
      documents = 0
      occurrences = 0
      searchable_characters = 0

      CSV.foreach(document_counts_path, headers: true, encoding: "bom|utf-8") do |row|
        documents += 1
        occurrences += row["occurrences"].to_i
        searchable_characters += row["searchable_characters"].to_i
      end

      {
        "documents" => documents,
        "occurrences" => occurrences,
        "searchable_characters" => searchable_characters
      }
    end

    def source_corpus_snapshot(source_prepared)
      snapshot = source_prepared.frozen_record&.fetch("corpus_snapshot", nil)
      raise ArgumentError, "Source prepared analysis has no frozen corpus snapshot" if snapshot.blank?

      snapshot.deep_dup
    end

    def corpus_snapshot_for(manifest)
      digest = Digest::SHA256.new
      digest.update("manifest-v#{Manifest::VERSION}\n")
      digest.update("generated-at:#{manifest.generated_at}\n")
      role_totals = Hash.new { |hash, role| hash[role] = { "documents" => 0, "source_bytes" => 0 } }

      manifest.documents.each do |document|
        digest.update(document["path"].to_s)
        digest.update("\0")
        digest.update(document["fingerprint"].to_s)
        digest.update("\n")

        role = document["document_role"].to_s.presence || DocumentRole.classify(document["path"])
        role_totals[role]["documents"] += 1
        role_totals[role]["source_bytes"] += document["size"].to_i
      end
      manifest_digest = digest.hexdigest

      {
        "version" => 2,
        "snapshot_id" => manifest_digest.first(16),
        "manifest_version" => Manifest::VERSION,
        "manifest_generated_at" => manifest.generated_at.to_s,
        "document_count" => manifest.documents.length,
        "manifest_digest" => manifest_digest,
        "manifest_by_document_role" => role_totals.sort.to_h
      }
    end

    def write_comparison_csv(path)
      comparison = @prepared_search.comparison
      return nil unless comparison&.requested?
      raise ArgumentError, comparison.errors.join(" ") unless comparison.valid?

      CSV.open(path, "w", encoding: "UTF-8", write_headers: true, headers: %w[dimension left_group right_group]) do |csv|
        csv << {
          "dimension" => comparison.dimension,
          "left_group" => comparison.left_group,
          "right_group" => comparison.right_group
        }
      end
      path
    end

    def write_methods(markdown_path, text_path, analysis_result, corpus_snapshot:, analysis_dir:)
      report = AnalysisReport.load(analysis_dir)
      overall = report&.overall.to_h
      comparison = @prepared_search.comparison
      roles = @query.document_roles.map { |role| I18n.t("corpus_search.roles.#{role}") }.join(", ")
      included_folders = @query.include_folders.presence&.join("; ") || "all folders in the selected text layers"
      excluded_folders = @query.exclude_folders.presence&.join("; ") || "none"
      filters = @query.metadata_filters.select { |_key, value| value.present? }
      filter_text = filters.any? ? filters.map { |key, value| "#{key}=#{value}" }.join("; ") : "none"

      comparison_section = if comparison
        effects = report&.comparison_effects.to_a.to_h { |row| [row["measure"], row["value"]] }
        observed_ratio = effects["rate_ratio_left_over_right"].to_s.presence
        <<~TEXT
          ## Scope comparison

          The same text query was compared across the **#{comparison.dimension}** groups
          **#{comparison.left_group}** and **#{comparison.right_group}**. Rates use searchable
          body characters as exposure. The exported effect table reports the left/right rate
          ratio, its approximate 95% Poisson interval, the absolute rate difference per million
          characters, the document-prevalence difference, and a one-degree-of-freedom Poisson
          log-likelihood statistic.#{observed_ratio ? " The observed left/right rate ratio was #{observed_ratio}." : " Exposure-based effect estimates were unavailable because at least one scope had no searchable body characters."}
        TEXT
      else
        ""
      end

      markdown = <<~MARKDOWN
        # Methods

        A search for **#{@query.display_label}** was run against the Fanya Hanwen Corpus
        snapshot `#{corpus_snapshot["snapshot_id"]}` (manifest generated
        #{corpus_snapshot["manifest_generated_at"]}). The search mode was
        `#{@query.mode}`. Punctuation handling was `#{@query.punctuation}`, and character
        matching was `#{@query.character_equivalence}` using registry version
        `#{@query.character_equivalence_version}`.

        Metadata headers were excluded before matching and never contributed to snippets,
        occurrence counts, or denominators. The selected text layers were: #{roles}.
        Included folders: #{included_folders}. Excluded folders: #{excluded_folders}.
        Additional metadata filters: #{filter_text}.

        The analysis contained #{overall["documents"] || 0} documents,
        #{overall["searchable_characters"] || 0} searchable body characters, and
        #{overall["occurrences"] || 0} matched occurrences. Normalized frequency was
        calculated as occurrences divided by searchable body characters, multiplied by
        1,000,000. Document prevalence was calculated as matching documents divided by
        all documents in scope.

        Ruby was invoked through the application-owned `standard_analysis` profile in a
        separate child process. Runtime: #{analysis_result.ruby_version || "unavailable"}. The exact
        script, input tables, output tables, figures, warnings, timing, and runtime information
        are included in this bundle.

        ## Advanced analyses

        Character-neighbour tables use the five nearest body characters retained on each
        side of every occurrence. Punctuation, separator, and control characters are removed
        during export, and positions L1–L5 and R1–R5 are summarized separately and together. The actual
        source form matched for each entered term is also retained, so exact/common/broad character matching
        can be audited as a form distribution. OR searches
        are additionally summarized by matched alternative, while proximity searches are
        summarized by observed source order.

        Dispersion is reported as Deviation of Proportions (DP), comparing each document's
        observed share of occurrences with its expected share based on searchable body
        characters. DPnorm divides DP by `1 - min(s)`, where `s` is the vector of document
        exposure shares; `1 - DPnorm` is shown as an intuitive evenness transform. Exact-body
        SHA-256 fingerprints identify byte-for-byte identical body texts after metadata
        removal. Default counts retain all stored documents, while the exported sensitivity
        table counts one unit per exact body fingerprint.

        Dated documents are grouped into historical 100-year bins. Their normalized rates
        receive exact Poisson count intervals. When at least 20 dated documents, five distinct
        date midpoints, and five occurrences are available, a document-level Poisson model
        estimates rate change per century with `log(searchable_characters)` as an offset. If
        Pearson residual dispersion exceeds 1.5, quasi-Poisson standard errors are reported.
        The time model is descriptive and does not establish historical causation. A fixed-seed
        reproducible sample of matching documents and occurrences is exported for manual inspection;
        sample rows retain their original IDs so they can be joined back to the full tables. When two
        scopes are compared, neighbouring-character keyness is calculated from the same five-character
        windows with log-ratios and a two-by-two log-likelihood statistic.

        References for DP and corrected DPnorm: Gries (2008), International Journal of Corpus
        Linguistics 13(4), 403–437; Lijffijt and Gries (2012), International Journal of Corpus
        Linguistics 17(1), 147–149, doi:10.1075/ijcl.17.1.08lij.

        #{comparison_section}
      MARKDOWN

      markdown_path.write(markdown)
      text_path.write(markdown.gsub(/^#+\s*/, "").gsub(/\*\*/, "").gsub(/`/, ""))
    end

    def write_citation(path, corpus_snapshot:)
      comparison = @prepared_search.comparison
      description = comparison ? "#{@query.display_label}; #{comparison.display_label}" : @query.display_label
      path.write(<<~TEXT)
        Suggested citation
        ==================

        Fanya Hanwen Corpus. "Corpus search analysis: #{description}."
        Prepared record #{@prepared_search.id}, corpus snapshot #{corpus_snapshot["snapshot_id"]}
        (manifest generated #{corpus_snapshot["manifest_generated_at"]}), accessed and exported
        #{Time.now.utc.iso8601}.

        Live query URL:
        #{public_url(@query.relative_url(include_presentation: false))}

        Frozen result URL:
        #{public_url(frozen_result_path)}
      TEXT
    end

    def write_research_manifest(path, output_dir, corpus_snapshot:)
      files = artifact_rows(
        output_dir,
        include_zip: false,
        exclude: [path.basename.to_s, "checksums.sha256"]
      )
      payload = {
        "version" => 1,
        "generated_at" => Time.now.utc.iso8601,
        "prepared_record_id" => @prepared_search.id,
        "query" => @query.to_h,
        "comparison" => @prepared_search.comparison&.to_h,
        "live_query_url" => public_url(@query.relative_url(include_presentation: false)),
        "frozen_result_url" => public_url(frozen_result_path),
        "corpus_snapshot" => corpus_snapshot,
        "files" => files
      }
      path.write(JSON.pretty_generate(payload))
    end

    def write_checksums(path, output_dir)
      rows = artifact_rows(
        output_dir,
        include_zip: false,
        exclude: [path.basename.to_s]
      )
      path.write(rows.map { |row| "#{row.fetch("sha256")}  #{row.fetch("path")}" }.join("
") + "
")
    end

    def artifact_rows(output_dir, include_zip:, exclude: [])
      root = Pathname(output_dir)
      excluded = Array(exclude)
      Dir.glob(root.join("**", "*"), File::FNM_DOTMATCH).sort.filter_map do |entry|
        file = Pathname(entry)
        next unless file.file?
        relative = file.relative_path_from(root).to_s
        next if excluded.include?(relative)
        next if !include_zip && file.extname == ".zip"

        {
          "path" => relative,
          "bytes" => file.size,
          "sha256" => Digest::SHA256.file(file).hexdigest
        }
      end
    end

    def write_streamed_datasets(result_path, flashcard_path, document_path, occurrence_path, dataset_writer)
      hit_count = 0

      CSV.open(result_path, "w", encoding: "UTF-8") do |results_csv|
        CSV.open(flashcard_path, "w", encoding: "UTF-8") do |flashcards_csv|
          CSV.open(document_path, "w", encoding: "UTF-8", write_headers: true, headers: AnalysisDatasetWriter::COLUMNS) do |documents_csv|
            CSV.open(occurrence_path, "w", encoding: "UTF-8", write_headers: true, headers: ANALYSIS_OCCURRENCE_COLUMNS) do |occurrences_csv|
              results_csv << RESULT_COLUMNS
              flashcards_csv << FLASHCARD_COLUMNS

              progress = lambda do |files_scanned, files_total|
                check_cancelled!
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
                check_cancelled!
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

    ANALYSIS_NEIGHBOUR_CHARACTERS = 5

    def analysis_occurrence_row(hit, occurrence_id:)
      {
        "occurrence_id" => occurrence_id,
        "occurrence_key" => hit["occurrence_key"],
        "doc_id" => hit["doc_id"],
        "document_id" => hit["document_id"],
        "work_id" => hit["work_id"],
        "path" => hit["path"],
        "source_url" => hit["source_url"],
        "mode" => @query.mode,
        "search_start_offset" => hit["search_start_offset"],
        "search_end_offset" => hit["search_end_offset"],
        "proximity_span" => @query.proximity? ? hit["search_end_offset"].to_i - hit["search_start_offset"].to_i : nil,
        "matched_term_order" => matched_term_order(hit),
        "matched_alternatives" => @query.alternatives? ? matched_alternatives(hit).join(" | ") : nil,
        "matched_forms" => matched_forms(hit),
        "left_neighbours" => context_tail(hit["left_context"], ANALYSIS_NEIGHBOUR_CHARACTERS),
        "right_neighbours" => context_head(hit["right_context"], ANALYSIS_NEIGHBOUR_CHARACTERS)
      }
    end


    def matched_forms(hit)
      source_characters = hit["matched_text"].to_s.each_char.to_a
      matches = Array(hit["term_matches"])

      pairs = if matches.any?
        matches.map do |match|
          relative_start = match["start_offset"].to_i - hit["start_offset"].to_i
          length = match["end_offset"].to_i - match["start_offset"].to_i
          source_form = source_characters.slice(relative_start, length).to_a.join
          [match["term"].to_s, source_form]
        end
      else
        [[@query.query_text.to_s, hit["matched_text"].to_s]]
      end

      pairs.reject { |query_form, source_form| query_form.empty? || source_form.empty? }
        .uniq
        .map { |query_form, source_form| "#{query_form}⇒#{source_form}" }
        .join(" | ")
    end

    def context_head(value, length)
      linguistic_context_characters(value).first(length).join
    end

    def context_tail(value, length)
      linguistic_context_characters(value).last(length).to_a.join
    end

    def linguistic_context_characters(value)
      value.to_s.each_char.reject { |character| character.match?(/[\p{P}\p{Z}\p{C}]/) }
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

    def write_metadata(path, hit_count, corpus_snapshot:, dataset_stats:, analysis_result:)
      metadata = {
        "version" => 10,
        "generated_at" => Time.now.utc.iso8601,
        "prepared_record_id" => @prepared_search.id,
        "source_prepared_id" => @prepared_search.source_prepared_id,
        "query" => @query.to_h,
        "comparison" => @prepared_search.comparison&.to_h,
        "live_query_path" => @query.relative_url(include_presentation: false),
        "corpus_snapshot" => corpus_snapshot,
        "manifest_generated_at" => corpus_snapshot["manifest_generated_at"],
        "hit_count" => hit_count,
        "analysis_dataset" => {
          "body_only" => true,
          "documents" => dataset_stats["documents"],
          "searchable_characters" => dataset_stats["searchable_characters"],
          "occurrences" => dataset_stats["occurrences"],
          "file" => "document_counts.csv",
          "occurrence_file" => "analysis_occurrences.csv"
        },
        "analysis" => {
          "profile" => analysis_result.profile,
          "status" => analysis_result.status,
          "ruby_version" => analysis_result.ruby_version,
          "duration_seconds" => analysis_result.duration_seconds,
          "directory" => "analysis/standard",
          "report" => "analysis/standard/analysis_report.json"
        },
        "reproducibility" => {
          "query" => "query.json",
          "query_urls" => "query_urls.txt",
          "corpus_snapshot" => "corpus_snapshot.json",
          "rerun_instructions" => "RERUN_ANALYSIS.txt",
          "methods_markdown" => "METHODS.md",
          "methods_text" => "METHODS.txt",
          "citation" => "CITATION.txt",
          "research_manifest" => "research_manifest.json",
          "checksums" => "checksums.sha256"
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
          I18n.t("corpus_search.export.metadata_notes.analysis_dataset"),
          "analysis_occurrences.csv stores only the five nearest non-punctuation body characters on each side for neighbour analysis; metadata is never copied into those fields.",
          "body_fingerprint is a SHA-256 digest of the body after metadata removal and is used only for exact-text sensitivity checks."
        ]
      }

      path.write(JSON.pretty_generate(metadata))
    end

    def write_research_readme(path, analysis_result, corpus_snapshot:)
      comparison_note = if @prepared_search.comparison
        "comparison.csv          Reproducible two-scope comparison definition.
"
      else
        ""
      end

      path.write(<<~TEXT)
        Fanya Hanwen Corpus search and analysis export
        ===============================================

        Prepared record: #{@prepared_search.id}
        Corpus snapshot: #{corpus_snapshot["snapshot_id"]}
        Query: #{@query.display_label}
        Search mode: #{@query.mode}
        Character matching: #{@query.character_equivalence}
        Punctuation: #{@query.punctuation}
        Analysis profile: #{analysis_result.profile}
        Analysis status: #{analysis_result.status}
        Ruby runtime: #{analysis_result.ruby_version || "unavailable"}

        Core files
        ----------
        results.csv              One row per matched occurrence.
        flashcards.csv           Compact flashcard export.
        document_counts.csv      One body-only row per document in scope,
                                 including documents with zero matches.
        analysis_occurrences.csv Compact occurrence offsets plus short body-only
                                 left/right contexts used by the advanced analyses.
        analysis_dataset.json    Dataset provenance and query definition.
        query.json               Normalized query and comparison definition.
        query_urls.txt           Live and frozen URLs for this record.
        corpus_snapshot.json     Immutable corpus and selected-scope fingerprint.
        RERUN_ANALYSIS.txt       Exact command for reproducing the analysis outputs.
        metadata.json            Export-wide provenance.
        #{comparison_note}METHODS.md               Citation-ready methods description.
        METHODS.txt              Plain-text copy of the methods description.
        CITATION.txt             Suggested citation and record identifiers.
        research_manifest.json   Query, corpus snapshot, and artifact hashes.
        checksums.sha256         SHA-256 checksums for bundle verification.

        Standard Ruby analysis
        -------------------
        analysis/standard/analysis.rb
                                 Exact application-owned Ruby script used.
        analysis/standard/analysis_report.json
                                 Machine-readable summary and chart manifest.
        analysis/standard/*_summary.csv
                                 Complete grouped tables for period, nation,
                                 region, author, folder branch, and corpus layer.
        analysis/standard/comparison_summary.csv
                                 The two selected scopes, when comparison was requested.
        analysis/standard/comparison_effects.csv
                                 Rate ratios, differences, interval, and likelihood statistic.
        analysis/standard/neighbour_*.csv
                                 Left/right character distributions around matches.
        analysis/standard/dispersion_summary.csv
                                 Document-level DP, corrected DPnorm, and range.
        analysis/standard/character_form_summary.csv
                                 Entered forms compared with the forms actually matched.
        analysis/standard/sample_*.csv
                                 Fixed-seed samples and their sampling manifest.
        analysis/standard/time_bins.csv
                                 Century rates and Poisson count intervals for dated texts.
        analysis/standard/time_trend_model.csv
                                 Exploratory Poisson or quasi-Poisson century trend.
        analysis/standard/duplicate_body_*.csv
                                 Exact-body duplicate groups and their members.
        analysis/standard/exact_body_sensitivity.csv
                                 Stored-document totals compared with unique exact bodies.
        analysis/standard/figures/*.svg
                                 Scalable browser and publication figures.
        analysis/standard/figures/*.png
                                 Raster copies suitable for slides.
        analysis/standard/runtime_info.txt
                                 Exact Ruby runtime and standard-library dependencies.
        analysis/standard/run_metadata.json
                                 Timing, limits, command, inputs, and status.

        Re-running the analysis
        -------------------------
        See RERUN_ANALYSIS.txt. The command uses only the body-only tables in this
        bundle and the copied analysis.rb script. No access to the live corpus is
        required.

        Metadata headers were not searched and are not included in searchable-
        character denominators. Descriptive metadata columns only label corpus
        documents and analytical groups.
      TEXT
    end

    def copy_analysis_readme(directory)
      source = Rails.root.join("analysis", "ruby", "README.md")
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
