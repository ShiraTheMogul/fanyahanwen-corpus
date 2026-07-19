# frozen_string_literal: true

require "csv"
require "json"
require "minitest/autorun"
require "tmpdir"
require_relative "../../analysis/ruby/profiles/standard_analysis"

class StandardAnalysisMetadataQualityTest < Minitest::Test
  DOCUMENT_HEADERS = %w[
    doc_id document_id work_id body_fingerprint duplicate_group_size representative_document_id duplicate_members_json
    path folder_path document_role canonical_parent_path title work author date_text year_start year_end nation corpus_root
    macro_region polity period region searchable_characters occurrences matching_document matched_terms_json
  ].freeze

  OCCURRENCE_HEADERS = %w[
    occurrence_id occurrence_key doc_id document_id work_id path source_url mode search_start_offset search_end_offset
    proximity_span matched_term_order matched_alternatives matched_forms left_neighbours right_neighbours
  ].freeze

  def test_reports_fallback_ids_metadata_coverage_and_scope_conflicts
    Dir.mktmpdir do |dir|
      documents = File.join(dir, "document_counts.csv")
      occurrences = File.join(dir, "analysis_occurrences.csv")
      output = File.join(dir, "output")
      Dir.mkdir(output)
      File.write(File.join(output, "nation_summary.csv"), "stale\n", encoding: "UTF-8")

      write_csv(documents, DOCUMENT_HEADERS, [
        document_row(
          "doc_id" => "100", "document_id" => "100", "work_id" => "10",
          "path" => "中國漢文/clean/清朝/大清/甲/甲.txt", "folder_path" => "中國漢文/clean/清朝/大清/甲",
          "title" => "甲", "work" => "甲", "corpus_root" => "中國漢文", "macro_region" => "中國",
          "period" => "清朝", "polity" => "大清", "year_start" => "1700", "year_end" => "1700"
        ),
        document_row(
          "doc_id" => "a" * 24, "document_id" => "a" * 24, "work_id" => "20",
          "path" => "中國漢文/clean/清朝/大清/乙/乙.txt", "folder_path" => "中國漢文/clean/清朝/大清/乙",
          "title" => "乙", "work" => "乙", "corpus_root" => "中國漢文", "macro_region" => "中國"
        ),
        document_row(
          "doc_id" => "b" * 24, "document_id" => "b" * 24, "work_id" => "",
          "path" => "中國漢文/clean/周朝/楚辭/亂曰.txt", "folder_path" => "中國漢文/clean/周朝/楚辭",
          "title" => "亂曰", "work" => "卷第十五", "corpus_root" => "中國漢文", "macro_region" => ""
        ),
        document_row(
          "doc_id" => "103", "document_id" => "103", "work_id" => "30",
          "path" => "中國漢文/clean/清朝/大清/避地日本感賦/避地日本感賦.txt", "folder_path" => "中國漢文/clean/清朝/大清/避地日本感賦",
          "title" => "避地日本感賦", "work" => "避地日本感賦", "corpus_root" => "日本漢文", "macro_region" => "日本"
        )
      ])
      write_csv(occurrences, OCCURRENCE_HEADERS, [{
        "occurrence_id" => "1", "occurrence_key" => "100:0:2:0:2", "doc_id" => "100",
        "document_id" => "100", "work_id" => "10", "path" => "中國漢文/clean/清朝/大清/甲/甲.txt",
        "source_url" => "", "mode" => "exact", "search_start_offset" => "0", "search_end_offset" => "2",
        "proximity_span" => "", "matched_term_order" => "", "matched_alternatives" => "",
        "matched_forms" => "詩曰⇒詩曰", "left_neighbours" => "", "right_neighbours" => ""
      }])

      StandardAnalysis.new(document_path: documents, occurrence_path: occurrences, output_dir: output).run

      quality = read_metric_csv(File.join(output, "identifier_quality_summary.csv"))
      assert_equal "4", quality.fetch("documents")
      assert_equal "2", quality.fetch("numeric_document_ids")
      assert_equal "2", quality.fetch("fallback_document_ids")
      assert_equal "3", quality.fetch("numeric_work_ids")
      assert_equal "1", quality.fetch("missing_work_ids")
      assert_equal "2", quality.fetch("fully_stable_documents")

      fallback_rows = CSV.read(File.join(output, "identifier_fallback_documents.csv"), headers: true, encoding: "UTF-8")
      assert_equal 2, fallback_rows.length
      assert_includes fallback_rows.map { |row| row["reason"] }, "path_hash_document_id;missing_work_id"

      work_rows = CSV.read(File.join(output, "identifier_fallback_works.csv"), headers: true, encoding: "UTF-8")
      assert_equal 2, work_rows.length

      coverage = CSV.read(File.join(output, "metadata_field_coverage.csv"), headers: true, encoding: "UTF-8").each_with_object({}) { |row, hash| hash[row["field"]] = row }
      assert_equal "2", coverage.fetch("document_id")["present"]
      assert_equal "1", coverage.fetch("year_range")["present"]

      root_conflicts = CSV.read(File.join(output, "scope_metadata_conflicts.csv"), headers: true, encoding: "UTF-8")
      assert_equal 1, root_conflicts.length
      macro_conflicts = CSV.read(File.join(output, "macro_region_scope_conflicts.csv"), headers: true, encoding: "UTF-8")
      assert_equal 1, macro_conflicts.length

      refute File.exist?(File.join(output, "nation_summary.csv"))
      warnings = File.read(File.join(output, "warnings.txt"), encoding: "UTF-8")
      assert_includes warnings, "2 document(s) still use path-hash"
      assert_includes warnings, "1 document(s) have no numeric work_id"
    end
  end

  private

  def document_row(overrides)
    defaults = DOCUMENT_HEADERS.to_h { |header| [header, ""] }
    defaults.merge!(
      "body_fingerprint" => "f" * 64,
      "duplicate_group_size" => "1",
      "representative_document_id" => overrides.fetch("doc_id", "1"),
      "duplicate_members_json" => "[]",
      "document_role" => "canonical",
      "nation" => overrides.fetch("corpus_root", "中國漢文"),
      "searchable_characters" => "100",
      "occurrences" => "0",
      "matching_document" => "0",
      "matched_terms_json" => "[]"
    ).merge(overrides)
  end

  def write_csv(path, headers, rows)
    CSV.open(path, "w", write_headers: true, headers: headers, encoding: "UTF-8") do |csv|
      rows.each { |row| csv << headers.map { |header| row[header] } }
    end
  end

  def read_metric_csv(path)
    CSV.read(path, headers: true, encoding: "UTF-8").to_h { |row| [row["metric"], row["value"]] }
  end
end
