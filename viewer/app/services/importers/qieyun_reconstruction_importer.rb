# frozen_string_literal: true

require "digest"

module Importers
  # Imports both reconstructed editions as one DictionaryWork with edition-aware
  # sections and entries. The existing catalogue route remains stable:
  # /dictionary/catalogue/:corpus_work_id
  class QieyunReconstructionImporter
    IMPORT_SCHEMA_VERSION = 2
    DEFAULT_LOG_EVERY = 500

    def self.import!(dataset:, replace: false, verbose: true, log_every: DEFAULT_LOG_EVERY)
      ensure_tables!

      existing = DictionaryWork.find_by(corpus_work_id: dataset.work_id)
      if existing && current?(existing, dataset)
        puts "[qieyun-dictionary] already current: #{existing.title} (#{existing.entry_count} entries)" if verbose
        return result_for(existing, status: "already_current")
      end

      if existing && !replace
        raise "Dictionary work #{dataset.work_id} already exists with a different fingerprint. Rerun with --replace only after reviewing the dry-run plan."
      end

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      counts = Hash.new(0)
      work = nil

      ActiveRecord::Base.transaction do
        delete_existing_work!(existing) if existing

        work = DictionaryWork.create!(
          corpus_work_id: dataset.work_id,
          title: dataset.title,
          edition_label: dataset.editions.map { |edition| edition.fetch("edition_label") }.join("／"),
          source_label: "Fanya Hanwen Corpus",
          parser_name: DictionaryImport::QieyunReconstructionDataset::PARSER_NAME,
          parser_version: DictionaryImport::QieyunReconstructionDataset::PARSER_VERSION,
          import_fingerprint: dataset.input_sha256,
          entry_count: dataset.entries.length,
          section_count: dataset.sections.length,
          reading_count: dataset.entries.sum { |entry| entry.fetch("fanqie").length },
          entry_character_count: dataset.entries.count { |entry| dataset.linkable_headword?(entry.fetch("headword")) },
          reference_count: dataset.entries.length,
          group_count: dataset.entries.count { |entry| entry.fetch("group_head") },
          imported_at: Time.current,
          import_metadata: {
            "qieyun_reconstruction_import_schema_version" => IMPORT_SCHEMA_VERSION,
            "multi_edition" => true,
            "reconstruction" => true,
            "source_revision" => dataset.source_revision,
            "entries_sha256" => dataset.input_sha256,
            "editions" => dataset.editions
          }
        )

        section_map = dataset.sections.each_with_object({}) do |section_row, memo|
          section = work.dictionary_sections.create!(
            sequence_number: section_row.fetch("sequence_number"),
            label: section_row.fetch("label"),
            tone: section_row.fetch("tone"),
            rhyme_number: section_row.fetch("edition_section_sequence"),
            rhyme_label: section_row.fetch("rhyme_label"),
            initial: nil,
            metadata: section_row.fetch("metadata")
          )
          memo[section_row.fetch("sequence_number")] = section
          counts[:sections] += 1
        end

        codepoint_cache = {}
        dataset.entries.each_with_index do |row, index|
          section = section_map.fetch(row.fetch("section_sequence"))
          entry = work.dictionary_entries.create!(
            dictionary_section: section,
            corpus_document_id: row.fetch("document_id"),
            sequence_number: row.fetch("sequence_number"),
            group_sequence: row.fetch("group_sequence"),
            small_rime_number: row.fetch("group_sequence"),
            group_head: row.fetch("group_head"),
            initial: nil,
            headword: row.fetch("headword"),
            definition: row["definition"],
            raw_payload: row.fetch("raw_payload"),
            parser_name: DictionaryImport::QieyunReconstructionDataset::PARSER_NAME,
            parser_version: DictionaryImport::QieyunReconstructionDataset::PARSER_VERSION,
            source_line_start: row.fetch("source_line_start"),
            source_line_end: row.fetch("source_line_end"),
            contains_unresolved_glyph: row.fetch("contains_unresolved_glyph"),
            review_required: false,
            metadata: row.fetch("metadata")
          )
          counts[:entries] += 1

          row.fetch("fanqie").each_with_index do |fanqie, position|
            entry.dictionary_readings.create!(
              position: position + 1,
              kind: "fanqie",
              value: fanqie,
              raw_value: "#{fanqie}反",
              metadata: {
                "edition_id" => row.fetch("edition_id"),
                "edition_label" => row.fetch("edition_label"),
                "reconstruction" => true
              }
            )
            counts[:readings] += 1
          end

          if dataset.linkable_headword?(row.fetch("headword"))
            glyph = row.fetch("headword")
            codepoint = codepoint_cache[glyph] ||= CharacterCodepoint.find_or_create_by!(codepoint: glyph.ord) do |record|
              record.chr = glyph
            end
            entry.dictionary_entry_characters.create!(
              character_codepoint: codepoint,
              position: 1,
              role: row.fetch("group_head") ? "group_head" : "primary",
              glyph: glyph
            )
            counts[:entry_characters] += 1
          end

          entry.dictionary_references.create!(
            position: 1,
            source_kind: "corpus_text",
            source_label: "Fanya Hanwen Corpus",
            corpus_work_id: dataset.work_id,
            corpus_document_id: row.fetch("document_id"),
            source_path: row.fetch("source_path"),
            source_file: row.fetch("source_file"),
            line_start: row.fetch("source_line_start"),
            line_end: row.fetch("source_line_end"),
            raw_sha256: Digest::SHA256.hexdigest(row.fetch("raw_payload")),
            metadata: {
              "edition_id" => row.fetch("edition_id"),
              "edition_label" => row.fetch("edition_label"),
              "reconstruction" => true
            }
          )
          counts[:references] += 1

          if verbose && ((index + 1) % log_every).zero?
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
            rate = (index + 1) / [elapsed, 0.001].max
            puts "[qieyun-dictionary] entries=#{index + 1}/#{dataset.entries.length} readings=#{counts[:readings]} characters=#{counts[:entry_characters]} rate=#{rate.round(1)}/s elapsed=#{elapsed.round(1)}s"
          end
        end

        verify!(work, dataset, counts)
      end

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      puts "[qieyun-dictionary] complete title=#{work.title.inspect} editions=#{dataset.editions.length} entries=#{counts[:entries]} sections=#{counts[:sections]} elapsed=#{elapsed.round(2)}s" if verbose

      result_for(work, status: "imported").merge(
        editions: dataset.editions.length,
        readings: counts[:readings],
        entry_characters: counts[:entry_characters],
        references: counts[:references],
        elapsed_seconds: elapsed.round(3)
      )
    end

    def self.current?(work, dataset)
      work.import_fingerprint == dataset.input_sha256 &&
        work.entry_count == dataset.entries.length &&
        work.section_count == dataset.sections.length &&
        work.import_metadata["qieyun_reconstruction_import_schema_version"].to_i == IMPORT_SCHEMA_VERSION
    end

    def self.ensure_tables!
      raise "Dictionary tables do not exist. Run bin/rails db:migrate first." unless DictionaryWork.table_exists?
    end

    def self.delete_existing_work!(work)
      return unless work

      entry_ids = DictionaryEntry.where(dictionary_work_id: work.id).select(:id)
      DictionaryReading.where(dictionary_entry_id: entry_ids).delete_all
      DictionaryEntryCharacter.where(dictionary_entry_id: entry_ids).delete_all
      DictionaryReference.where(dictionary_entry_id: entry_ids).delete_all
      DictionaryEntry.where(dictionary_work_id: work.id).delete_all
      DictionarySection.where(dictionary_work_id: work.id).delete_all
      work.destroy!
    end

    def self.verify!(work, dataset, counts)
      expected = {
        sections: dataset.sections.length,
        entries: dataset.entries.length,
        readings: dataset.entries.sum { |entry| entry.fetch("fanqie").length },
        entry_characters: dataset.entries.count { |entry| dataset.linkable_headword?(entry.fetch("headword")) },
        references: dataset.entries.length
      }
      actual = {
        sections: work.dictionary_sections.count,
        entries: work.dictionary_entries.count,
        readings: counts[:readings],
        entry_characters: counts[:entry_characters],
        references: counts[:references]
      }
      failures = actual.select { |name, value| value != expected.fetch(name) }
      return if failures.empty?

      detail = failures.map { |name, value| "#{name}=#{value} expected=#{expected.fetch(name)}" }.join(", ")
      raise "Qieyun dictionary verification failed: #{detail}"
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
        import_schema_version: work.import_metadata["qieyun_reconstruction_import_schema_version"]
      }
    end
  end
end
