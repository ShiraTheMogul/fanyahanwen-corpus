# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "pathname"
require "time"

module DictionaryImport
  class ValidationError < StandardError; end

  # Loads one reviewed dictionary JSONL file and proves that it still points to
  # the expected corpus work and documents before any database import occurs.
  #
  # This class is deliberately Rails-free. The same validation can therefore be
  # used by a plain Ruby planning script and by the Rails importer.
  class ReadyJsonl
    REQUIRED_KEYS = %w[
      dictionary_title
      dictionary_work_id
      document_id
      source_file
      source_path
      source_line_start
      source_line_end
      sequence_number
      section_sequence
      headword
      headwords
      definition
      payload_raw
      parser
      parser_version
      dry_run_status
      parser_review_required
      contains_source_gap
    ].freeze

    READY_STATUS = "ready_for_import_review"

    attr_reader :entries_path, :corpus_root, :expected_entries, :rows,
                :errors, :warnings, :documents, :work_metadata,
                :input_sha256, :started_at, :metadata_edition_label

    def initialize(entries_path:, corpus_root:, expected_entries: nil)
      @entries_path = Pathname.new(entries_path).expand_path
      @corpus_root = Pathname.new(corpus_root).expand_path
      @expected_entries = expected_entries&.to_i
      @rows = []
      @errors = []
      @warnings = []
      @documents = {}
      @work_metadata = nil
      @input_sha256 = nil
      @metadata_edition_label = nil
      @started_at = Time.now.utc
    end

    def load!
      validate_paths
      return self unless errors.empty?

      @input_sha256 = Digest::SHA256.file(entries_path).hexdigest
      read_rows
      validate_dataset
      validate_corpus_metadata
      validate_source_windows if errors.empty?
      self
    end

    def valid?
      errors.empty?
    end

    def raise_if_invalid!
      return self if valid?

      raise ValidationError, "Dictionary import plan has #{errors.length} blocker(s). See blockers.csv."
    end

    def dictionary_title
      rows.first&.fetch("dictionary_title", nil)
    end

    def corpus_work_id
      rows.first&.fetch("dictionary_work_id", nil)
    end

    def parser_name
      rows.first&.fetch("parser", nil)
    end

    def parser_version
      rows.first&.fetch("parser_version", nil)
    end

    def sections
      @sections ||= rows.group_by { |row| integer(row["section_sequence"]) }
                         .sort_by { |sequence, _| sequence }
                         .map do |sequence, section_rows|
        first = section_rows.first
        {
          "sequence_number" => sequence,
          "tone" => blank_to_nil(first["tone"]),
          "rhyme_number" => nullable_integer(first["rhyme_number"]),
          "rhyme_label" => blank_to_nil(first["rhyme_label"]),
          "initial" => blank_to_nil(first["initial"]),
          "label" => section_label(first),
          "entry_count" => section_rows.length,
          "group_count" => section_rows.map { |row| nullable_integer(row["group_sequence"]) }.compact.uniq.length,
          "document_ids" => section_rows.map { |row| integer(row["document_id"]) }.uniq.sort
        }
      end
    end

    def reading_count
      rows.count { |row| present?(row["pronunciation_marker_raw"]) }
    end

    def entry_character_count
      rows.sum { |row| Array(row["headwords"]).length }
    end

    def unique_character_count
      rows.flat_map { |row| Array(row["headwords"]) }.uniq.length
    end

    def group_count
      rows.map do |row|
        sequence = nullable_integer(row["group_sequence"])
        next if sequence.nil?

        [integer(row["section_sequence"]), sequence]
      end.compact.uniq.length
    end

    def summary
      {
        "schema_version" => 1,
        "created_at" => Time.now.utc.iso8601,
        "entries_file" => entries_path.to_s,
        "entries_sha256" => input_sha256,
        "corpus_root" => corpus_root.to_s,
        "dictionary_title" => dictionary_title,
        "corpus_work_id" => corpus_work_id,
        "parser" => parser_name,
        "parser_version" => parser_version,
        "metadata_edition_label" => metadata_edition_label,
        "entries" => rows.length,
        "sections" => sections.length,
        "groups" => group_count,
        "readings" => reading_count,
        "entry_characters" => entry_character_count,
        "unique_characters" => unique_character_count,
        "documents" => documents.length,
        "blockers" => errors.length,
        "warnings" => warnings.length,
        "database_writes" => 0,
        "passed" => valid?
      }
    end

    def write_plan(output_dir:, edition_label:, source_label:)
      requested_edition_label = edition_label.to_s.strip
      if metadata_edition_label && !requested_edition_label.empty? && requested_edition_label != metadata_edition_label
        mismatch = blocker("edition_label_mismatch", "requested=#{requested_edition_label.inspect}; metadata=#{metadata_edition_label.inspect}")
        errors << mismatch unless errors.include?(mismatch)
      end
      effective_edition_label = metadata_edition_label || blank_to_nil(requested_edition_label)

      output = Pathname.new(output_dir).expand_path
      unsafe_outputs = [Pathname.new("/").expand_path, Pathname.pwd.expand_path, corpus_root]
      raise ValidationError, "Refusing unsafe output directory: #{output}" if unsafe_outputs.include?(output)

      FileUtils.rm_rf(output)
      FileUtils.mkdir_p(output)

      write_summary(output)
      write_blockers(output)
      write_warnings(output)
      write_sections(output)
      write_documents(output)

      manifest = summary.merge(
        "edition_label" => effective_edition_label,
        "source_label" => source_label.to_s,
        "table_plan" => {
          "dictionary_works" => valid? ? 1 : 0,
          "dictionary_sections" => valid? ? sections.length : 0,
          "dictionary_entries" => valid? ? rows.length : 0,
          "dictionary_readings" => valid? ? reading_count : 0,
          "dictionary_entry_characters" => valid? ? entry_character_count : 0,
          "dictionary_references" => valid? ? rows.length : 0
        }
      )
      File.write(output.join("import_manifest.json"), JSON.pretty_generate(manifest) + "\n", encoding: "UTF-8")
      output
    end

    private

    def validate_paths
      errors << blocker("entries_file_missing", entries_path.to_s) unless entries_path.file?
      errors << blocker("corpus_root_missing", corpus_root.to_s) unless corpus_root.directory?
    end

    def read_rows
      seen_sequences = {}

      File.foreach(entries_path, encoding: "UTF-8").with_index(1) do |line, line_number|
        next if line.strip.empty?

        begin
          row = JSON.parse(line)
        rescue JSON::ParserError => e
          errors << blocker("invalid_json", "line #{line_number}: #{e.message}")
          next
        end

        unless row.is_a?(Hash)
          errors << blocker("row_not_object", "line #{line_number}")
          next
        end

        missing = REQUIRED_KEYS.reject { |key| row.key?(key) }
        errors << blocker("missing_required_keys", "line #{line_number}: #{missing.join(', ')}") if missing.any?

        sequence = nullable_integer(row["sequence_number"])
        if sequence
          if seen_sequences.key?(sequence)
            errors << blocker("duplicate_sequence_number", "#{sequence} on lines #{seen_sequences[sequence]} and #{line_number}")
          else
            seen_sequences[sequence] = line_number
          end
        end

        rows << row
      end

      errors << blocker("empty_entries_file", entries_path.to_s) if rows.empty?
    end

    def validate_dataset
      return if rows.empty?

      if expected_entries && rows.length != expected_entries
        errors << blocker("unexpected_entry_count", "expected #{expected_entries}, got #{rows.length}")
      end

      assert_one_value("dictionary_title")
      assert_one_value("dictionary_work_id")
      assert_one_value("parser")
      assert_one_value("parser_version")

      sequences = rows.map { |row| nullable_integer(row["sequence_number"]) }.compact.sort
      expected_sequence = (1..rows.length).to_a
      unless sequences == expected_sequence
        errors << blocker("non_contiguous_sequence_numbers", "expected 1..#{rows.length}; got #{sequences.first.inspect}..#{sequences.last.inspect}")
      end

      rows.each_with_index do |row, index|
        row_number = index + 1

        unless row["dry_run_status"].to_s == READY_STATUS
          errors << blocker("row_not_ready", "row #{row_number}: #{row['dry_run_status'].inspect}")
        end
        if truthy?(row["parser_review_required"])
          errors << blocker("row_requires_parser_review", "row #{row_number}")
        end
        if truthy?(row["contains_source_gap"])
          errors << blocker("row_contains_source_gap", "row #{row_number}")
        end

        headword = row["headword"].to_s
        headwords = Array(row["headwords"]).map(&:to_s)
        if headword.each_char.count != 1
          errors << blocker("headword_not_one_character", "row #{row_number}: #{headword.inspect}")
        end
        unless headwords.include?(headword)
          errors << blocker("primary_headword_missing_from_headwords", "row #{row_number}: #{headword.inspect}")
        end
        if headwords.any? { |glyph| glyph.each_char.count != 1 }
          errors << blocker("entry_character_not_one_character", "row #{row_number}: #{headwords.inspect}")
        end

        %w[dictionary_work_id document_id sequence_number section_sequence source_line_start source_line_end].each do |key|
          errors << blocker("invalid_integer", "row #{row_number}: #{key}=#{row[key].inspect}") if nullable_integer(row[key]).nil?
        end
      end

      validate_section_consistency
    end

    def validate_section_consistency
      rows.group_by { |row| nullable_integer(row["section_sequence"]) }.each do |sequence, section_rows|
        next if sequence.nil?

        %w[tone rhyme_number rhyme_label initial].each do |key|
          values = section_rows.map { |row| normalized_scalar(row[key]) }.uniq
          next if values.length <= 1

          errors << blocker("inconsistent_section_field", "section #{sequence}: #{key}=#{values.inspect}")
        end
      end
    end

    def validate_corpus_metadata
      return if rows.empty?

      grouped_paths = rows.group_by { |row| row["source_path"].to_s }
      metadata_paths = grouped_paths.keys.map do |relative_path|
        corpus_root.join(relative_path).dirname.join("metadata.json")
      end.uniq

      if metadata_paths.length != 1
        errors << blocker("multiple_work_metadata_files", metadata_paths.map(&:to_s).join(" | "))
        return
      end

      metadata_path = metadata_paths.first
      unless metadata_path.file?
        errors << blocker("metadata_missing", metadata_path.to_s)
        return
      end

      begin
        @work_metadata = JSON.parse(metadata_path.read(encoding: "UTF-8"))
      rescue JSON::ParserError => e
        errors << blocker("metadata_invalid_json", "#{metadata_path}: #{e.message}")
        return
      end

      if integer(work_metadata["work_id"]) != integer(corpus_work_id)
        errors << blocker("work_id_mismatch", "JSONL=#{corpus_work_id.inspect}; metadata=#{work_metadata['work_id'].inspect}")
      end
      if work_metadata["title"].to_s != dictionary_title.to_s
        errors << blocker("work_title_mismatch", "JSONL=#{dictionary_title.inspect}; metadata=#{work_metadata['title'].inspect}")
      end

      metadata_document_rows = []
      Array(work_metadata["documents"]).each do |document|
        metadata_document_rows << document.merge("_edition_label" => nil)
      end
      Array(work_metadata["editions"]).each do |edition|
        Array(edition["documents"]).each do |document|
          metadata_document_rows << document.merge("_edition_label" => edition["edition_label"])
        end
      end

      metadata_documents = metadata_document_rows.each_with_object({}) do |document, memo|
        document_id = integer(document["document_id"])
        if memo.key?(document_id)
          errors << blocker("duplicate_document_id_in_metadata", document_id.to_s)
        else
          memo[document_id] = document
        end
      end

      used_edition_labels = []
      rows.group_by { |row| integer(row["document_id"]) }.each do |document_id, document_rows|
        metadata_document = metadata_documents[document_id]
        if metadata_document.nil?
          errors << blocker("document_id_missing_from_metadata", document_id.to_s)
          next
        end

        source_path = document_rows.first["source_path"].to_s
        source_file = document_rows.first["source_file"].to_s
        if metadata_document["path"].to_s != source_path
          errors << blocker("document_path_mismatch", "document #{document_id}: JSONL=#{source_path.inspect}; metadata=#{metadata_document['path'].inspect}")
        end
        if metadata_document["file"].to_s != source_file
          errors << blocker("document_file_mismatch", "document #{document_id}: JSONL=#{source_file.inspect}; metadata=#{metadata_document['file'].inspect}")
        end

        live_path = corpus_root.join(source_path)
        unless live_path.file?
          errors << blocker("source_file_missing", live_path.to_s)
          next
        end

        used_edition_labels << metadata_document["_edition_label"] if present?(metadata_document["_edition_label"])

        documents[document_id] = {
          "document_id" => document_id,
          "source_path" => source_path,
          "source_file" => source_file,
          "sha256" => Digest::SHA256.file(live_path).hexdigest,
          "entry_count" => document_rows.length,
          "edition_label" => blank_to_nil(metadata_document["_edition_label"])
        }
      end

      labels = used_edition_labels.compact.uniq
      if labels.length > 1
        errors << blocker("multiple_editions_in_one_import", labels.inspect)
      else
        @metadata_edition_label = labels.first
      end
    end

    def validate_source_windows
      line_cache = {}

      rows.each_with_index do |row, index|
        source_path = row["source_path"].to_s
        lines = line_cache[source_path] ||= corpus_root.join(source_path).read(encoding: "UTF-8").lines
        start_line = integer(row["source_line_start"])
        end_line = integer(row["source_line_end"])
        from = [start_line - 5, 0].max
        to = [end_line + 1, lines.length - 1].min
        window = lines[from..to].to_a.join

        headword = row["headword"].to_s
        fanqie = row["fanqie"].to_s.sub(/切\z/, "")

        unless window.include?(headword)
          warnings << blocker("headword_not_found_near_source_lines", "row #{index + 1}: #{source_path}:#{start_line}-#{end_line} #{headword.inspect}")
        end
        if present?(fanqie) && !window.include?(fanqie)
          errors << blocker("fanqie_not_found_near_source_lines", "row #{index + 1}: #{source_path}:#{start_line}-#{end_line} #{row['fanqie'].inspect}")
        end
      end
    end

    def assert_one_value(key)
      values = rows.map { |row| normalized_scalar(row[key]) }.uniq
      return if values.length == 1

      errors << blocker("multiple_#{key}", values.inspect)
    end

    def write_summary(output)
      data = summary
      File.write(output.join("summary.json"), JSON.pretty_generate(data) + "\n", encoding: "UTF-8")
      text = <<~TEXT
        DICTIONARY DATABASE IMPORT PLAN
        ===============================
        Passed:                       #{data['passed']}
        Dictionary:                   #{data['dictionary_title']}
        Corpus work ID:               #{data['corpus_work_id']}
        Entries:                      #{data['entries']}
        Sections:                     #{data['sections']}
        Groups:                       #{data['groups']}
        Readings:                     #{data['readings']}
        Entry characters:             #{data['entry_characters']}
        Unique characters:            #{data['unique_characters']}
        Corpus documents:             #{data['documents']}
        Blockers:                     #{data['blockers']}
        Warnings:                     #{data['warnings']}
        Database writes:              0
        Input SHA-256:                #{data['entries_sha256']}
      TEXT
      File.write(output.join("summary.txt"), text, encoding: "UTF-8")
    end

    def write_blockers(output)
      CSV.open(output.join("blockers.csv"), "w", write_headers: true, headers: %w[code detail], encoding: "UTF-8") do |csv|
        errors.each { |error| csv << [error["code"], error["detail"]] }
      end
    end

    def write_warnings(output)
      CSV.open(output.join("warnings.csv"), "w", write_headers: true, headers: %w[code detail], encoding: "UTF-8") do |csv|
        warnings.each { |warning| csv << [warning["code"], warning["detail"]] }
      end
    end

    def write_sections(output)
      headers = %w[sequence_number label tone rhyme_number rhyme_label initial entry_count group_count document_ids]
      CSV.open(output.join("sections.csv"), "w", write_headers: true, headers: headers, encoding: "UTF-8") do |csv|
        sections.each do |section|
          csv << headers.map do |header|
            value = section[header]
            value.is_a?(Array) ? value.join("|") : value
          end
        end
      end
    end

    def write_documents(output)
      headers = %w[document_id source_file source_path sha256 entry_count]
      CSV.open(output.join("documents.csv"), "w", write_headers: true, headers: headers, encoding: "UTF-8") do |csv|
        documents.values.sort_by { |document| document["document_id"] }.each do |document|
          csv << headers.map { |header| document[header] }
        end
      end
    end

    def section_label(row)
      [blank_to_nil(row["tone"]), nullable_integer(row["rhyme_number"]), blank_to_nil(row["rhyme_label"])].compact.join("｜")
    end

    def blocker(code, detail)
      { "code" => code, "detail" => detail.to_s }
    end

    def normalized_scalar(value)
      value.is_a?(String) ? value.strip : value
    end

    def blank_to_nil(value)
      string = value.to_s.strip
      string.empty? ? nil : string
    end

    def present?(value)
      !blank_to_nil(value).nil?
    end

    def truthy?(value)
      value == true || value.to_s == "true" || value.to_s == "1"
    end

    def integer(value)
      Integer(value)
    rescue ArgumentError, TypeError
      0
    end

    def nullable_integer(value)
      return nil if value.nil? || value.to_s.strip.empty?

      Integer(value)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
