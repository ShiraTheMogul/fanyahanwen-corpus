# frozen_string_literal: true

require "digest"
require "json"
require Rails.root.join("lib/dictionary_import/ready_jsonl").to_s

module Importers
  class DictionaryCatalogueImporter
    DEFAULT_LOG_EVERY = 500
    IMPORT_SCHEMA_VERSION = 2

    def self.import!(entries_path:, corpus_root:, expected_entries:, edition_label:, source_label:,
                     replace: false, verbose: true, log_every: DEFAULT_LOG_EVERY)
      dataset = DictionaryImport::ReadyJsonl.new(
        entries_path: entries_path,
        corpus_root: corpus_root,
        expected_entries: expected_entries
      ).load!
      dataset.raise_if_invalid!

      requested_edition_label = blank_to_nil(edition_label)
      if dataset.metadata_edition_label && requested_edition_label && requested_edition_label != dataset.metadata_edition_label
        raise "Edition label mismatch: requested=#{requested_edition_label.inspect}; metadata=#{dataset.metadata_edition_label.inspect}"
      end
      effective_edition_label = dataset.metadata_edition_label || requested_edition_label

      unless DictionaryWork.table_exists?
        raise "Dictionary tables do not exist. Run bin/rails db:migrate first."
      end

      existing = DictionaryWork.find_by(corpus_work_id: dataset.corpus_work_id)
      if existing
        if existing.import_fingerprint == dataset.input_sha256 &&
           existing.entry_count == dataset.rows.length &&
           existing.import_metadata["import_schema_version"].to_i == IMPORT_SCHEMA_VERSION
          puts "[dictionary-import] already current: #{existing.title} (#{existing.entry_count} entries)" if verbose
          return result_for(existing, status: "already_current")
        end

        unless replace
          raise "Dictionary work #{dataset.corpus_work_id} already exists with a different fingerprint or import schema. Rerun with REPLACE=1 only after reviewing the new plan."
        end
      end

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      imported_entries = 0
      imported_readings = 0
      imported_characters = 0
      imported_references = 0
      codepoint_cache = {}

      work = nil

      ActiveRecord::Base.transaction do
        delete_existing_work!(existing) if existing

        work = DictionaryWork.create!(
          corpus_work_id: dataset.corpus_work_id,
          title: dataset.dictionary_title,
          edition_label: effective_edition_label,
          source_label: source_label,
          parser_name: dataset.parser_name,
          parser_version: dataset.parser_version,
          import_fingerprint: dataset.input_sha256,
          entry_count: dataset.rows.length,
          section_count: dataset.sections.length,
          reading_count: dataset.reading_count,
          entry_character_count: dataset.entry_character_count,
          reference_count: dataset.rows.length,
          group_count: dataset.group_count,
          imported_at: Time.current,
          import_metadata: {
            "import_schema_version" => IMPORT_SCHEMA_VERSION,
            "entries_sha256" => dataset.input_sha256,
            "corpus_root_at_import" => Pathname.new(corpus_root).expand_path.to_s,
            "documents" => dataset.documents.values.sort_by { |document| document["document_id"] },
            "group_count" => dataset.group_count,
            "unique_character_count" => dataset.unique_character_count
          }
        )

        section_map = dataset.sections.each_with_object({}) do |section, memo|
          record = work.dictionary_sections.create!(
            sequence_number: section["sequence_number"],
            label: section["label"],
            tone: section["tone"],
            rhyme_number: section["rhyme_number"],
            rhyme_label: section["rhyme_label"],
            initial: section["initial"],
            metadata: {
              "entry_count" => section["entry_count"],
              "group_count" => section["group_count"],
              "document_ids" => section["document_ids"],
              "initials" => section["initials"],
              "initial_count" => section["initial_count"]
            }
          )
          memo[section["sequence_number"]] = record
        end

        dataset.rows.each_with_index do |row, index|
          section_sequence = integer(row.fetch("section_sequence"))
          section = section_map.fetch(section_sequence)

          entry = work.dictionary_entries.create!(
            dictionary_section: section,
            corpus_document_id: integer(row.fetch("document_id")),
            sequence_number: integer(row.fetch("sequence_number")),
            group_sequence: nullable_integer(row["group_sequence"]),
            small_rime_number: nullable_integer(row["small_rime_number"]),
            group_head: truthy?(row["is_group_head"]),
            initial: blank_to_nil(row["initial"]),
            headword: row.fetch("headword").to_s,
            definition: blank_to_nil(row["definition"]),
            raw_payload: row.fetch("payload_raw").to_s,
            parser_name: row.fetch("parser").to_s,
            parser_version: row.fetch("parser_version").to_s,
            source_line_start: integer(row.fetch("source_line_start")),
            source_line_end: integer(row.fetch("source_line_end")),
            contains_unresolved_glyph: truthy?(row["contains_unresolved_glyph"]),
            review_required: truthy?(row["parser_review_required"]),
            metadata: entry_metadata(row)
          )
          imported_entries += 1

          marker_raw = row["pronunciation_marker_raw"].to_s.strip
          unless marker_raw.empty?
            entry.dictionary_readings.create!(
              position: 1,
              kind: row["pronunciation_marker_type"].to_s.strip.empty? ? "unspecified" : row["pronunciation_marker_type"].to_s,
              value: blank_to_nil(row["fanqie"]),
              raw_value: marker_raw,
              metadata: {}
            )
            imported_readings += 1
          end

          Array(row["headwords"]).map(&:to_s).each_with_index do |glyph, position|
            codepoint = codepoint_cache[glyph] ||= find_or_create_codepoint!(glyph)
            entry.dictionary_entry_characters.create!(
              character_codepoint: codepoint,
              position: position + 1,
              role: if position.zero?
                      truthy?(row["is_group_head"]) ? "group_head" : "primary"
                    else
                      "associated_headword"
                    end,
              glyph: glyph
            )
            imported_characters += 1
          end

          entry.dictionary_references.create!(
            position: 1,
            source_kind: "corpus_text",
            source_label: source_label,
            corpus_work_id: dataset.corpus_work_id,
            corpus_document_id: integer(row.fetch("document_id")),
            source_path: row.fetch("source_path").to_s,
            source_file: row.fetch("source_file").to_s,
            line_start: integer(row.fetch("source_line_start")),
            line_end: integer(row.fetch("source_line_end")),
            raw_sha256: Digest::SHA256.hexdigest(row.fetch("payload_raw").to_s),
            metadata: {}
          )
          imported_references += 1

          if verbose && ((index + 1) % log_every).zero?
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
            rate = (index + 1) / [elapsed, 0.001].max
            puts "[dictionary-import] entries=#{index + 1}/#{dataset.rows.length} readings=#{imported_readings} characters=#{imported_characters} rate=#{rate.round(1)}/s elapsed=#{elapsed.round(1)}s"
          end
        end

        verify_import!(work, dataset, imported_entries, imported_readings, imported_characters, imported_references)
      end

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      puts "[dictionary-import] complete title=#{work.title.inspect} entries=#{imported_entries} sections=#{work.dictionary_sections.count} elapsed=#{elapsed.round(2)}s" if verbose

      result_for(work, status: "imported").merge(
        readings: imported_readings,
        entry_characters: imported_characters,
        references: imported_references,
        elapsed_seconds: elapsed.round(3)
      )
    end

    def self.delete_existing_work!(work)
      entry_ids = DictionaryEntry.where(dictionary_work_id: work.id).select(:id)
      DictionaryReading.where(dictionary_entry_id: entry_ids).delete_all
      DictionaryEntryCharacter.where(dictionary_entry_id: entry_ids).delete_all
      DictionaryReference.where(dictionary_entry_id: entry_ids).delete_all
      DictionaryEntry.where(dictionary_work_id: work.id).delete_all
      DictionarySection.where(dictionary_work_id: work.id).delete_all
      work.destroy!
    end

    def self.verify_import!(work, dataset, entries, readings, characters, references)
      checks = {
        entries: [entries, dataset.rows.length],
        sections: [work.dictionary_sections.count, dataset.sections.length],
        readings: [readings, dataset.reading_count],
        entry_characters: [characters, dataset.entry_character_count],
        references: [references, dataset.rows.length]
      }

      failed = checks.select { |_name, (actual, expected)| actual != expected }
      return if failed.empty?

      detail = failed.map { |name, (actual, expected)| "#{name}=#{actual} expected=#{expected}" }.join(", ")
      raise "Dictionary import verification failed: #{detail}"
    end

    def self.entry_metadata(row)
      {
        "tone_section" => blank_to_nil(row["tone_section"]),
        "initial" => blank_to_nil(row["initial"]),
        "payload_parts" => Array(row["payload_parts"]),
        "source_structure_notes" => Array(row["source_structure_notes"]),
        "validation_notes" => Array(row["validation_notes"]),
        "dry_run_status" => row["dry_run_status"].to_s
      }.reject { |_key, value| value.nil? || value == [] }
    end

    def self.find_or_create_codepoint!(glyph)
      raise "Expected one Unicode character, got #{glyph.inspect}" unless glyph.each_char.count == 1

      CharacterCodepoint.find_or_create_by!(codepoint: glyph.ord) do |record|
        record.chr = glyph
      end
    end

    def self.result_for(work, status:)
      {
        status: status,
        dictionary_work_id: work.id,
        corpus_work_id: work.corpus_work_id,
        title: work.title,
        sections: work.section_count,
        entries: work.entry_count,
        readings: work.reading_count,
        fingerprint: work.import_fingerprint,
        import_schema_version: work.import_metadata["import_schema_version"]
      }
    end

    def self.blank_to_nil(value)
      string = value.to_s.strip
      string.empty? ? nil : string
    end

    def self.truthy?(value)
      value == true || value.to_s == "true" || value.to_s == "1"
    end

    def self.integer(value)
      Integer(value)
    end

    def self.nullable_integer(value)
      return nil if value.nil? || value.to_s.strip.empty?

      Integer(value)
    end
  end
end
