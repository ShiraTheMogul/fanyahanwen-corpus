# frozen_string_literal: true

require "digest"
require "json"
require "roo"
require "pathname"

module Importers
  class LegacyStructuredDictionaryCatalogueImporter
    LOG_EVERY = 500
    KANGXI_WORK_ID = 127355
    SHUOWEN_WORK_ID = 79_653

    def self.plan(kangxi_xlsx:, shuowen_xlsx:)
      {
        "kangxi" => build_kangxi(kangxi_xlsx),
        "shuowen" => build_shuowen(shuowen_xlsx)
      }
    end

    def self.import!(kind:, source_path:, replace: false, verbose: true)
      dataset = case kind.to_s
                when "kangxi" then build_kangxi(source_path)
                when "shuowen" then build_shuowen(source_path)
                else raise ArgumentError, "Unknown structured dictionary: #{kind.inspect}"
                end
      raise dataset["blockers"].join("\n") if dataset["blockers"].any?

      existing = DictionaryWork.find_by(corpus_work_id: dataset.fetch("corpus_work_id"))
      if existing&.import_fingerprint == dataset.fetch("fingerprint")
        return result(existing, "already_current")
      end
      raise "Dictionary already exists with a different fingerprint; use REPLACE=1 after reviewing the plan" if existing && !replace

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      work = nil
      ActiveRecord::Base.transaction do
        delete_work!(existing) if existing
        work = DictionaryWork.create!(
          corpus_work_id: dataset.fetch("corpus_work_id"),
          title: dataset.fetch("title"),
          edition_label: dataset["edition_label"],
          source_label: dataset.fetch("source_label"),
          parser_name: dataset.fetch("parser_name"),
          parser_version: dataset.fetch("parser_version"),
          import_fingerprint: dataset.fetch("fingerprint"),
          entry_count: dataset.fetch("entries").length,
          section_count: dataset.fetch("sections").length,
          reading_count: 0,
          entry_character_count: dataset.fetch("entries").count { |e| e["linked_glyph"].present? },
          reference_count: dataset.fetch("entries").sum { |e| e.fetch("source_rows").length },
          group_count: 0,
          imported_at: Time.current,
          import_metadata: dataset.fetch("work_metadata")
        )

        section_map = dataset.fetch("sections").to_h do |section|
          record = work.dictionary_sections.create!(
            sequence_number: section.fetch("sequence_number"),
            label: section.fetch("label"),
            raw_heading: section["raw_heading"],
            metadata: section.fetch("metadata")
          )
          [section.fetch("sequence_number"), record]
        end

        cache = {}
        dataset.fetch("entries").each_with_index do |row, index|
          entry = work.dictionary_entries.create!(
            dictionary_section: section_map.fetch(row.fetch("section_sequence")),
            corpus_document_id: nil,
            sequence_number: index + 1,
            group_sequence: nil,
            small_rime_number: nil,
            group_head: false,
            headword: row.fetch("headword"),
            definition: row.fetch("definition"),
            raw_payload: row.fetch("raw_payload"),
            parser_name: dataset.fetch("parser_name"),
            parser_version: dataset.fetch("parser_version"),
            source_line_start: nil,
            source_line_end: nil,
            contains_unresolved_glyph: row.fetch("raw_payload").include?("□") || row.fetch("raw_payload").include?("�"),
            review_required: false,
            metadata: row.fetch("metadata")
          )

          if row["linked_glyph"].present?
            glyph = row.fetch("linked_glyph")
            cp = cache[glyph] ||= CharacterCodepoint.find_or_create_by!(codepoint: glyph.ord) { |r| r.chr = glyph }
            entry.dictionary_entry_characters.create!(character_codepoint: cp, position: 1, role: "primary", glyph: glyph)
          end

          row.fetch("source_rows").each_with_index do |source_row, position|
            entry.dictionary_references.create!(
              position: position + 1,
              source_kind: "structured_resource",
              source_label: dataset.fetch("source_label"),
              corpus_work_id: dataset.fetch("corpus_work_id"),
              corpus_document_id: nil,
              source_path: dataset.fetch("source_path"),
              source_file: File.basename(dataset.fetch("source_path")),
              line_start: nil,
              line_end: nil,
              source_record_key: source_row.fetch("record_key"),
              raw_sha256: Digest::SHA256.hexdigest(source_row.fetch("canonical_record")),
              metadata: source_row.except("canonical_record")
            )
          end

          if verbose && ((index + 1) % LOG_EVERY).zero?
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
            puts "[legacy-dictionary-import] #{kind} entries=#{index + 1}/#{dataset['entries'].length} rate=#{((index + 1) / [elapsed, 0.001].max).round(1)}/s"
          end
        end

        verify!(work, dataset)
      end
      result(work, "imported")
    end

    def self.build_kangxi(path)
      rows = read_sheet(path)
      radicals = KangxiRadical.order(:number).to_a
      radical_map = {}
      radicals.each do |radical|
        ([radical.radical, radical.simplified] + radical.variants.to_s.split(/[、,，\s]+/)).compact.reject(&:blank?).each do |glyph|
          radical_map[glyph] = radical
        end
      end

      blockers = []
      blockers << "Expected 214 Kangxi radicals; found #{radicals.length}" unless radicals.length == 214
      grouped = rows.group_by { |r| [r.fetch("繁體"), r.fetch("康熙字典解釋")] }
      entries = grouped.values.sort_by { |group| group.map { |r| r.fetch("_row") }.min }.map do |group|
        first = group.first
        radical = radical_map[first.fetch("部首")]
        blockers << "Unmapped Kangxi radical #{first['部首'].inspect} at row #{first['_row']}" unless radical
        glyph = first.fetch("繁體")
        linked = glyph.each_char.count == 1 ? glyph : nil
        membership = if linked && radical
                       codepoint = CharacterCodepoint.find_by(chr: linked)
                       CharacterRadicalMembership.find_by(character_codepoint_id: codepoint&.id, radical_number: radical.number)
                     end
        {
          "section_sequence" => radical&.number,
          "headword" => glyph,
          "linked_glyph" => linked,
          "definition" => first.fetch("康熙字典解釋"),
          "raw_payload" => first.fetch("康熙字典解釋"),
          "metadata" => {
            "dictionary_path" => first["字典路徑"],
            "volume_label" => first["集 1"],
            "radical" => first["部首"],
            "total_strokes" => integer_or_nil(first["筆劃數"]),
            "additional_strokes" => membership&.additional_strokes,
            "ordering_key" => [radical&.number, membership&.additional_strokes, first.fetch("_row")],
            "duplicate_source_rows" => group.length
          },
          "source_rows" => group.map { |r| source_row(r, "kx") }
        }
      end

      legacy_count = CharacterProperty.where(source: "Kangxi", field: "kangxi_gloss").count
      blockers << "Legacy Kangxi parity mismatch: structured=#{entries.length}; legacy=#{legacy_count}" unless legacy_count == entries.length

      sections = radicals.map do |radical|
        {
          "sequence_number" => radical.number,
          "label" => "#{radical.radical}部",
          "raw_heading" => nil,
          "metadata" => radical.attributes.slice("number", "radical", "variants", "stroke_count", "meaning", "colloquial_names", "pinyin", "sino_vietnamese", "japanese", "korean", "frequency", "simplified", "examples").merge(
            "ordering_system" => "kangxi_radical"
          )
        }
      end
      dataset("御定康熙字典", KANGXI_WORK_ID, "四庫全書本", "Kangxi structured XLSX", "legacy_kangxi_xlsx_adapter", path, sections, entries, blockers,
              { "ordering_system" => "kangxi_radical", "legacy_entry_count" => legacy_count, "source_rows" => rows.length, "deduplicated_source_rows" => rows.length - entries.length })
    end

    def self.build_shuowen(path)
      rows = read_sheet(path)
      categories = []
      rows.each { |r| categories << r.fetch("shuowen_category") unless categories.include?(r.fetch("shuowen_category")) }
      components = ShuowenComponent.order(:number).to_a
      blockers = []
      blockers << "Expected 540 Shuowen categories; found #{categories.length}" unless categories.length == 540
      blockers << "Expected 540 legacy Shuowen components; found #{components.length}" unless components.length == 540

      sections = categories.each_with_index.map do |category, index|
        source_glyph = category.sub(/部\z/, "")
        legacy = components[index]
        {
          "sequence_number" => index + 1,
          "label" => category,
          "raw_heading" => category,
          "metadata" => {
            "ordering_system" => "shuowen_component",
            "source_glyph" => source_glyph,
            "legacy_component_glyph" => legacy&.glyph,
            "legacy_component_number" => legacy&.number,
            "source_legacy_glyph_mismatch" => legacy && legacy.glyph != source_glyph
          }
        }
      end
      category_sequence = categories.each_with_index.to_h { |category, index| [category, index + 1] }
      entries = rows.map do |row|
        raw_headword = row.fetch("character")
        linked = if raw_headword.each_char.count == 1
                   raw_headword
                 elsif raw_headword.match?(/\A\p{Han}[;；]\z/u)
                   raw_headword.each_char.first
                 end
        {
          "section_sequence" => category_sequence.fetch(row.fetch("shuowen_category")),
          "headword" => raw_headword,
          "linked_glyph" => linked,
          "definition" => row.fetch("entry"),
          "raw_payload" => row.fetch("entry"),
          "metadata" => {
            "category" => row.fetch("shuowen_category"),
            "ordering_key" => [category_sequence.fetch(row.fetch("shuowen_category")), row.fetch("_row")],
            "linked_glyph_normalized_from_headword" => linked.present? && linked != raw_headword
          },
          "source_rows" => [source_row(row, "shuowen")]
        }
      end
      legacy_count = CharacterProperty.where(source: "Shuowen Jiezi", field: "shuowen_entry").count
      blockers << "Legacy Shuowen parity mismatch: structured=#{entries.length}; legacy=#{legacy_count}" unless legacy_count == entries.length
      dataset("說文解字", SHUOWEN_WORK_ID, nil, "Shuowen structured XLSX", "legacy_shuowen_xlsx_adapter", path, sections, entries, blockers,
              { "ordering_system" => "shuowen_component", "legacy_entry_count" => legacy_count, "source_rows" => rows.length })
    end

    def self.dataset(title, work_id, edition, label, parser, path, sections, entries, blockers, metadata)
      canonical = JSON.generate({ title: title, sections: sections, entries: entries })
      {
        "title" => title,
        "corpus_work_id" => work_id,
        "edition_label" => edition,
        "source_label" => label,
        "parser_name" => parser,
        "parser_version" => "1",
        "source_path" => Pathname.new(path).relative_path_from(Rails.root).to_s,
        "sections" => sections,
        "entries" => entries,
        "blockers" => blockers.uniq,
        "warnings" => [],
        "fingerprint" => Digest::SHA256.hexdigest(canonical),
        "work_metadata" => metadata.merge("source_path" => Pathname.new(path).relative_path_from(Rails.root).to_s)
      }
    end

    def self.read_sheet(path)
      sheet = Roo::Excelx.new(path).sheet(0)
      headers = sheet.row(1).map { |h| h.to_s.strip }
      (2..sheet.last_row).map do |row_number|
        row = headers.each_with_index.to_h { |header, index| [header, sheet.cell(row_number, index + 1).to_s.strip] }
        row["_row"] = row_number
        row
      end
    end

    def self.source_row(row, sheet)
      canonical = row.keys.sort.reject { |k| k == "_row" }.map { |k| "#{k}=#{row[k]}" }.join("\n")
      { "record_key" => "#{sheet}!row=#{row.fetch('_row')}", "source_row" => row.fetch("_row"), "canonical_record" => canonical }
    end

    def self.integer_or_nil(value)
      Integer(value, exception: false)
    end

    def self.verify!(work, dataset)
      expected = {
        sections: dataset.fetch("sections").length,
        entries: dataset.fetch("entries").length,
        references: dataset.fetch("entries").sum { |e| e.fetch("source_rows").length }
      }
      actual = {
        sections: work.dictionary_sections.count,
        entries: work.dictionary_entries.count,
        references: DictionaryReference.joins(:dictionary_entry).where(dictionary_entries: { dictionary_work_id: work.id }).count
      }
      failed = expected.keys.select { |key| expected[key] != actual[key] }
      raise "Legacy dictionary import verification failed: #{failed.map { |k| "#{k}=#{actual[k]} expected=#{expected[k]}" }.join(', ')}" if failed.any?
    end

    def self.delete_work!(work)
      return unless work
      entry_ids = DictionaryEntry.where(dictionary_work_id: work.id).select(:id)
      DictionaryReading.where(dictionary_entry_id: entry_ids).delete_all
      DictionaryEntryCharacter.where(dictionary_entry_id: entry_ids).delete_all
      DictionaryReference.where(dictionary_entry_id: entry_ids).delete_all
      DictionaryEntry.where(dictionary_work_id: work.id).delete_all
      DictionarySection.where(dictionary_work_id: work.id).delete_all
      work.destroy!
    end

    def self.result(work, status)
      { status: status, dictionary_work_id: work.id, corpus_work_id: work.corpus_work_id, title: work.title, sections: work.section_count, entries: work.entry_count, references: work.reference_count }
    end
  end
end
