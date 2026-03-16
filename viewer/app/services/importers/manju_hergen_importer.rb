# frozen_string_literal: true

# Import Takekoshi 2011 Manchu-script Mandarin transcription data
# into character_properties from a prepared CSV.
#
# Expected CSV columns
# --------------------
# The importer expects the CSV generated from the Takekoshi pipeline, with
# columns like:
#   character
#   transcription_latin
#   transcription_manchu
#   transcription_ipa
#   initial_label
#   final_label
#   occurrence_count
#   page_number
#   source_chunk
#
# Design goals
# ------------
# - No hardcoded URLs in the DB. Only human citation strings in `source`.
# - Idempotent re-runs via find_or_create_by!
# - Keep each data layer separate:
#     latin  -> searchable Latin transcription
#     manchu -> actual Manchu-script form
#     ipa    -> pronunciation helper
# - Preserve useful provenance/grouping info when present.
# - Skip bad rows safely instead of crashing the whole import.
#
# Suggested usage from Rails console
# ----------------------------------
#   Importers::ManjuHergenImporter.import_csv(
#     path: "tmp/takekoshi_for_corpus.csv"
#   )
#
# Or with explicit fields/source:
#   Importers::ManjuHergenImporter.import_csv(
#     path: "tmp/takekoshi_for_corpus.csv",
#     source: "Takekoshi 竹越, Takeshi 孝. (2011). 『兼滿漢語滿洲套話清文啓蒙』満洲文字注音一覧表. KOTONOHA, (101).",
#     field_latin: "manju_hergen_latin",
#     field_manchu: "manju_hergen_manchu",
#     field_ipa: "manju_hergen_ipa"
#   )

require "csv"

module Importers
  class ManjuHergenImporter
    DEFAULT_SOURCE = "Takekoshi 竹越, Takeshi 孝. (2011). 『兼滿漢語滿洲套話清文啓蒙』満洲文字注音一覧表. KOTONOHA, (101).".freeze

    # We only import rows where `character` is exactly one Unicode scalar.
    # This avoids accidentally importing broken multi-character cells.
    def self.single_character?(value)
      return false if value.blank?

      value.to_s.each_char.count == 1
    end

    def self.codepoint_for_char(char)
      char.to_s.ord
    end

    def self.find_or_create_codepoint!(char)
      cp = codepoint_for_char(char)
      CharacterCodepoint.find_or_create_by!(codepoint: cp) do |row|
        row.chr = char
      end
    end

    def self.store_property!(cc:, source:, field:, value:)
      return if field.blank?
      return if value.blank?

      CharacterProperty.find_or_create_by!(
        character_codepoint_id: cc.id,
        source: source,
        field: field,
        value: value
      )
    end

    def self.import_csv(
      path:,
      source: DEFAULT_SOURCE,
      field_latin: "manju_hergen_latin",
      field_manchu: "manju_hergen_manchu",
      field_ipa: "manju_hergen_ipa",
      field_initial: "manju_hergen_initial",
      field_final: "manju_hergen_final",
      field_occurrence_count: "manju_hergen_occurrence_count",
      field_page_number: "manju_hergen_page_number",
      field_source_chunk: "manju_hergen_source_chunk",
      verbose: true
    )
      full_path = Rails.root.join(path).to_s
      raise "File not found: #{full_path}" unless File.exist?(full_path)

      imported = 0
      skipped = 0

      ActiveRecord::Base.transaction do
        CSV.foreach(full_path, headers: true, encoding: "bom|utf-8") do |row|
          character = row["character"].to_s.strip
          latin = row["transcription_latin"].to_s.strip
          manchu = row["transcription_manchu"].to_s.strip
          ipa = row["transcription_ipa"].to_s.strip
          initial_label = row["initial_label"].to_s.strip
          final_label = row["final_label"].to_s.strip
          occurrence_count = row["occurrence_count"].to_s.strip
          page_number = row["page_number"].to_s.strip
          source_chunk = row["source_chunk"].to_s.strip

          unless single_character?(character)
            skipped += 1
            next
          end

          # A transcription row without a Latin value is not useful for this importer.
          if latin.blank?
            skipped += 1
            next
          end

          cc = find_or_create_codepoint!(character)

          store_property!(cc: cc, source: source, field: field_latin, value: latin)
          store_property!(cc: cc, source: source, field: field_manchu, value: manchu)
          store_property!(cc: cc, source: source, field: field_ipa, value: ipa)

          # These auxiliary fields are useful for grouping/debugging and remain separate.
          store_property!(cc: cc, source: source, field: field_initial, value: initial_label)
          store_property!(cc: cc, source: source, field: field_final, value: final_label)
          store_property!(cc: cc, source: source, field: field_occurrence_count, value: occurrence_count)
          store_property!(cc: cc, source: source, field: field_page_number, value: page_number)
          store_property!(cc: cc, source: source, field: field_source_chunk, value: source_chunk)

          imported += 1

          if verbose && (imported % 500).zero?
            puts "[ManjuHergen] imported=#{imported} skipped=#{skipped}"
          end
        end
      end

      puts "[ManjuHergen] DONE imported=#{imported} skipped=#{skipped}" if verbose
      { imported: imported, skipped: skipped }
    end
  end
end
