# frozen_string_literal: true

require "digest"

module Importers
  # Imports each reconstructed 切韻 edition as its own DictionaryWork row.
  #
  # Both rows retain corpus_work_id 129688. corpus_edition_id distinguishes
  # them, and the catalogue selects one with ?edition=<edition ID>.
  class QieyunReconstructionImporter
    IMPORT_SCHEMA_VERSION = 3
    DEFAULT_LOG_EVERY = 500

    def self.import!(dataset:, replace: false, verbose: true, log_every: DEFAULT_LOG_EVERY)
      ensure_tables!
      ensure_edition_column!

      existing = DictionaryWork.where(corpus_work_id: dataset.work_id).order(:corpus_edition_id).to_a
      if current_set?(existing, dataset)
        puts "[qieyun-dictionary] both editions already current" if verbose
        return result_set(existing, status: "already_current")
      end

      if existing.any? && !replace
        raise "Dictionary work #{dataset.work_id} already exists in a combined or outdated form. Rerun with --replace after reviewing the dry run."
      end

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      imported_works = []

      ActiveRecord::Base.transaction do
        existing.each { |work| delete_existing_work!(work) }

        dataset.editions.sort_by { |edition| edition.fetch("edition_sequence") }.each do |edition|
          imported_works << import_edition!(
            dataset: dataset,
            edition: edition,
            verbose: verbose,
            log_every: log_every,
            overall_started_at: started_at
          )
        end
      end

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      puts "[qieyun-dictionary] complete editions=#{imported_works.length} elapsed=#{elapsed.round(2)}s" if verbose

      result_set(imported_works, status: "imported").merge(elapsed_seconds: elapsed.round(3))
    end

    def self.import_edition!(dataset:, edition:, verbose:, log_every:, overall_started_at:)
      edition_id = edition.fetch("edition_id")
      edition_label = edition.fetch("edition_label")
      section_rows = dataset.sections.select { |row| row.fetch("edition_id") == edition_id }
      entry_rows = dataset.entries.select { |row| row.fetch("edition_id") == edition_id }
      entries_by_section = entry_rows.group_by { |row| row.fetch("section_sequence") }

      counts = Hash.new(0)

      work = DictionaryWork.create!(
        corpus_work_id: dataset.work_id,
        corpus_edition_id: edition_id,
        title: dataset.title,
        edition_label: edition_label,
        source_label: "Fanya Hanwen Corpus",
        parser_name: DictionaryImport::QieyunReconstructionDataset::PARSER_NAME,
        parser_version: DictionaryImport::QieyunReconstructionDataset::PARSER_VERSION,
        import_fingerprint: edition.fetch("input_sha256"),
        entry_count: entry_rows.length,
        section_count: section_rows.length,
        reading_count: entry_rows.sum { |entry| entry.fetch("fanqie").length },
        entry_character_count: entry_rows.count { |entry| dataset.linkable_headword?(entry.fetch("headword")) },
        reference_count: entry_rows.length,
        group_count: entry_rows.count { |entry| entry.fetch("group_head") },
        imported_at: Time.current,
        import_metadata: {
          "qieyun_reconstruction_import_schema_version" => IMPORT_SCHEMA_VERSION,
          "reconstruction" => true,
          "source_revision" => dataset.source_revision,
          "entries_sha256" => edition.fetch("input_sha256"),
          "corpus_edition_id" => edition_id,
          "edition" => edition
        }
      )

      section_map = section_rows.each_with_object({}) do |section_row, memo|
        section_entries = entries_by_section.fetch(section_row.fetch("sequence_number"), [])
        section = work.dictionary_sections.create!(
          sequence_number: section_row.fetch("edition_section_sequence"),
          label: section_row.fetch("label"),
          tone: section_row.fetch("tone"),
          rhyme_number: section_row.fetch("edition_section_sequence"),
          rhyme_label: section_row.fetch("rhyme_label"),
          initial: nil,
          metadata: section_row.fetch("metadata").merge(
            "entry_count" => section_entries.length,
            "group_count" => section_entries.count { |entry| entry.fetch("group_head") }
          )
        )
        memo[section_row.fetch("sequence_number")] = section
        counts[:sections] += 1
      end

      codepoint_cache = {}

      entry_rows.each_with_index do |row, index|
        section = section_map.fetch(row.fetch("section_sequence"))
        entry = work.dictionary_entries.create!(
          dictionary_section: section,
          corpus_document_id: row.fetch("document_id"),
          sequence_number: row.fetch("edition_entry_sequence"),
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
              "edition_id" => edition_id,
              "edition_label" => edition_label,
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
            "edition_id" => edition_id,
            "edition_label" => edition_label,
            "reconstruction" => true
          }
        )
        counts[:references] += 1

        if verbose && ((index + 1) % log_every).zero?
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - overall_started_at
          puts "[qieyun-dictionary] edition=#{edition_label.inspect} entries=#{index + 1}/#{entry_rows.length} elapsed=#{elapsed.round(1)}s"
        end
      end

      verify_edition!(work, section_rows, entry_rows, dataset, counts)

      puts "[qieyun-dictionary] imported edition=#{edition_label.inspect} entries=#{counts[:entries]} sections=#{counts[:sections]}" if verbose
      work
    end

    def self.current_set?(works, dataset)
      return false unless works.length == dataset.editions.length
      return false if works.any? { |work| work.corpus_edition_id.nil? }

      by_edition = works.index_by(&:corpus_edition_id)
      dataset.editions.all? do |edition|
        work = by_edition[edition.fetch("edition_id")]
        work && current_edition?(work, edition)
      end
    end

    def self.current_edition?(work, edition)
      work.import_fingerprint == edition.fetch("input_sha256") &&
        work.entry_count == edition.fetch("entry_count") &&
        work.section_count == edition.fetch("section_count") &&
        work.import_metadata["qieyun_reconstruction_import_schema_version"].to_i == IMPORT_SCHEMA_VERSION
    end

    def self.ensure_tables!
      raise "Dictionary tables do not exist. Run bin/rails db:migrate first." unless DictionaryWork.table_exists?
    end

    def self.ensure_edition_column!
      return if DictionaryWork.column_names.include?("corpus_edition_id")

      raise "Dictionary edition support is not migrated. Run bin/rails db:migrate first."
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

    def self.verify_edition!(work, section_rows, entry_rows, dataset, counts)
      expected = {
        sections: section_rows.length,
        entries: entry_rows.length,
        readings: entry_rows.sum { |entry| entry.fetch("fanqie").length },
        entry_characters: entry_rows.count { |entry| dataset.linkable_headword?(entry.fetch("headword")) },
        references: entry_rows.length
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
      raise "Qieyun edition verification failed for #{work.edition_label}: #{detail}"
    end

    def self.result_set(works, status:)
      {
        status: status,
        corpus_work_id: works.first&.corpus_work_id,
        title: works.first&.title,
        editions: works.sort_by(&:corpus_edition_id).map { |work| result_for(work) },
        total_sections: works.sum(&:section_count),
        total_entries: works.sum(&:entry_count)
      }
    end

    def self.result_for(work)
      {
        dictionary_work_id: work.id,
        corpus_work_id: work.corpus_work_id,
        corpus_edition_id: work.corpus_edition_id,
        edition_label: work.edition_label,
        sections: work.section_count,
        entries: work.entry_count,
        readings: work.reading_count,
        fingerprint: work.import_fingerprint,
        catalogue_url: "/dictionary/catalogue/#{work.corpus_work_id}?edition=#{work.corpus_edition_id}"
      }
    end
  end
end
