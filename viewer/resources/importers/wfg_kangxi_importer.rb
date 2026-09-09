# frozen_string_literal: true

require "digest"
require "json"
require "sqlite3"
require Rails.root.join("app/services/dictionary_catalogue/wfg_kangxi_resource").to_s

module Importers
  class WfgKangxiImporter
    WORK_ID = 127_355
    PARSER_NAME = "wfg_kangxi_mdx"
    PARSER_VERSION = "1.0.0+wfg-2018-12-12"
    SOURCE_LABEL = "WFG《康熙字典》2018-12-12"
    RESOURCE_PATH = Rails.root.join("resources/kangxi/wfg_kangxi.sqlite3")

    RADICALS = "一丨丶丿乙亅二亠人儿入八冂冖冫几凵刀力勹匕匚匸十卜卩厂厶又口囗土士夂夊夕大女子宀寸小尢尸屮山巛工己巾干幺广廴廾弋弓彐彡彳心戈戶手支攴文斗斤方无日曰月木欠止歹殳毋比毛氏气水火爪父爻爿片牙牛犬玄玉瓜瓦甘生用田疋疒癶白皮皿目矛矢石示禸禾穴立竹米糸缶网羊羽老而耒耳聿肉臣自至臼舌舛舟艮色艸虍虫血行衣襾見角言谷豆豕豸貝赤走足身車辛辰辵邑酉釆里金長門阜隶隹雨靑非面革韋韭音頁風飛食首香馬骨高髟鬥鬯鬲鬼魚鳥鹵鹿麥麻黃黍黑黹黽鼎鼓鼠鼻齊齒龍龜龠".chars.freeze

    RADICAL_STROKES = begin
      counts = {}
      (1..6).each { |number| counts[number] = 1 }
      (7..29).each { |number| counts[number] = 2 }
      (30..60).each { |number| counts[number] = 3 }
      (61..94).each { |number| counts[number] = 4 }
      (95..117).each { |number| counts[number] = 5 }
      (118..146).each { |number| counts[number] = 6 }
      (147..166).each { |number| counts[number] = 7 }
      (167..175).each { |number| counts[number] = 8 }
      (176..186).each { |number| counts[number] = 9 }
      (187..194).each { |number| counts[number] = 10 }
      (195..200).each { |number| counts[number] = 11 }
      (201..204).each { |number| counts[number] = 12 }
      (205..208).each { |number| counts[number] = 13 }
      (209..210).each { |number| counts[number] = 14 }
      counts[211] = 15
      counts[212] = 16
      counts[213] = 16
      counts[214] = 17
      counts.freeze
    end

    class << self
      def plan
        verify_resource!
        metadata = resource_metadata
        {
          work_id: WORK_ID,
          source: SOURCE_LABEL,
          occurrences: metadata.fetch("occurrence_count").to_i,
          redirects: metadata.fetch("redirect_count").to_i,
          aliases: metadata.fetch("alias_count").to_i,
          blocks: metadata.fetch("block_count").to_i,
          resources: metadata.fetch("resource_count").to_i,
          mdx_sha256: metadata.fetch("mdx_sha256"),
          mdd_sha256: metadata.fetch("mdd_sha256"),
          resource_sha256: DictionaryCatalogue::WfgKangxiResource::SHA256
        }
      end

      def import!(replace: false, verbose: true, log_every: 1_000)
        verify_resource!
        ensure_tables!

        existing = DictionaryWork.find_by(corpus_work_id: WORK_ID, corpus_edition_id: nil)
        fingerprint = DictionaryCatalogue::WfgKangxiResource::SHA256
        if existing && current_import?(existing, fingerprint)
          puts "[wfg-kangxi] already current" if verbose
          return result(existing, "already_current")
        end
        if existing && !replace
          raise "Kangxi dictionary #{WORK_ID} already exists. Review dictionaries:wfg_kangxi:plan and rerun with REPLACE=1."
        end

        preserved_sections = preserve_section_metadata(existing)
        rows = resource_query("SELECT * FROM occurrences ORDER BY serial")
        aliases = resource_query("SELECT * FROM aliases ORDER BY serial, position").group_by { |row| row.fetch("serial").to_i }
        blocks = resource_query("SELECT * FROM blocks ORDER BY serial, position").group_by { |row| row.fetch("serial").to_i }
        section_counts = rows.each_with_object(Hash.new(0)) { |row, counts| counts[row.fetch("radical_number").to_i] += 1 }

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        imported = Hash.new(0)
        codepoint_cache = {}
        work = nil

        ActiveRecord::Base.transaction do
          delete_existing_work!(existing) if existing

          work = DictionaryWork.create!(
            corpus_work_id: WORK_ID,
            corpus_edition_id: nil,
            title: existing&.title.presence || "御定康熙字典",
            edition_label: nil,
            source_label: SOURCE_LABEL,
            parser_name: PARSER_NAME,
            parser_version: PARSER_VERSION,
            import_fingerprint: fingerprint,
            entry_count: rows.length,
            section_count: 214,
            reading_count: rows.sum { |row| [row["zhuyin"], row["pinyin"]].count { |value| value.to_s.present? } },
            entry_character_count: rows.count { |row| portable_character?(row.fetch("headword")) },
            reference_count: rows.length,
            group_count: 0,
            imported_at: Time.current,
            import_metadata: import_metadata
          )

          section_map = create_sections!(work, preserved_sections, section_counts)

          rows.each_with_index do |row, index|
            serial = row.fetch("serial").to_i
            entry = create_entry!(work, section_map.fetch(row.fetch("radical_number").to_i), row)
            imported[:entries] += 1

            reading_position = 0
            [["zhuyin", row["zhuyin"]], ["pinyin", row["pinyin"]]].each do |kind, raw_value|
              next if raw_value.to_s.blank?
              reading_position += 1
              entry.dictionary_readings.create!(
                position: reading_position,
                kind: kind,
                value: raw_value.to_s,
                raw_value: raw_value.to_s,
                metadata: { "source" => SOURCE_LABEL }
              )
              imported[:readings] += 1
            end

            headword = row.fetch("headword")
            if portable_character?(headword)
              codepoint = codepoint_cache[headword] ||= find_or_create_codepoint!(headword)
              entry.dictionary_entry_characters.create!(
                character_codepoint: codepoint,
                position: 1,
                role: "primary",
                glyph: headword
              )
              imported[:characters] += 1
            end

            Array(aliases[serial]).each do |alias_row|
              entry.dictionary_entry_aliases.create!(
                position: alias_row.fetch("position").to_i,
                kind: alias_row.fetch("kind"),
                form: alias_row.fetch("form"),
                is_pua: alias_row.fetch("is_pua").to_i == 1,
                metadata: parse_json(alias_row["metadata_json"])
              )
              imported[:aliases] += 1
            end

            Array(blocks[serial]).each do |block_row|
              entry.dictionary_entry_blocks.create!(
                position: block_row.fetch("position").to_i,
                kind: block_row.fetch("kind"),
                text: block_row.fetch("text"),
                metadata: parse_json(block_row["metadata_json"])
              )
              imported[:blocks] += 1
            end

            entry.dictionary_references.create!(
              position: 1,
              source_kind: "digital_dictionary",
              source_label: SOURCE_LABEL,
              corpus_work_id: WORK_ID,
              corpus_document_id: nil,
              source_path: DictionaryCatalogue::WfgKangxiResource::PATH,
              source_file: File.basename(DictionaryCatalogue::WfgKangxiResource::PATH),
              source_record_key: row.fetch("record_key"),
              line_start: nil,
              line_end: nil,
              raw_sha256: Digest::SHA256.hexdigest(row.fetch("raw_markup")),
              metadata: reference_metadata(row)
            )
            imported[:references] += 1

            if verbose && ((index + 1) % log_every).zero?
              elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
              puts "[wfg-kangxi] entries=#{index + 1}/#{rows.length} rate=#{((index + 1) / [elapsed, 0.001].max).round(1)}/s"
            end
          end

          verify_import!(work, imported)
        end

        DictionaryCatalogue::KangxiStructure.reset_cache! if defined?(DictionaryCatalogue::KangxiStructure)
        result(work, "imported").merge(imported)
      end

      private

      def verify_resource!
        return true if DictionaryCatalogue::WfgKangxiResource.available?

        raise "WFG Kangxi resource failed its SHA/count integrity checks: #{RESOURCE_PATH}"
      end

      def ensure_tables!
        required = [DictionaryWork, DictionarySection, DictionaryEntry, DictionaryEntryAlias, DictionaryEntryBlock]
        missing = required.reject(&:table_exists?)
        return if missing.empty?

        raise "Dictionary tables are missing (#{missing.map(&:table_name).join(', ')}). Run bin/rails db:migrate first."
      end

      def resource_database
        db = SQLite3::Database.new(RESOURCE_PATH.to_s, readonly: true)
        db.results_as_hash = true
        db
      end

      def resource_query(sql, *binds)
        db = resource_database
        db.execute(sql, binds).map do |row|
          row.each_with_object({}) { |(key, value), hash| hash[key.to_s] = value unless key.is_a?(Integer) }
        end
      ensure
        db&.close
      end

      def resource_metadata
        resource_query("SELECT key, value FROM metadata").to_h { |row| [row.fetch("key"), row.fetch("value")] }
      end

      def current_import?(work, fingerprint)
        work.import_fingerprint == fingerprint &&
          work.parser_name == PARSER_NAME &&
          work.parser_version == PARSER_VERSION &&
          work.entry_count == 47_043 &&
          work.section_count == 214
      end

      def preserve_section_metadata(work)
        return {} unless work

        work.dictionary_sections.each_with_object({}) do |section, result|
          result[section.sequence_number] = section.metadata.to_h.deep_dup
        end
      end

      def create_sections!(work, preserved, counts)
        RADICALS.each_with_index.each_with_object({}) do |(radical, index), result|
          number = index + 1
          metadata = preserved.fetch(number, {}).merge(
            "radical" => radical,
            "stroke_count" => RADICAL_STROKES.fetch(number),
            "entry_count" => counts.fetch(number, 0),
            "source" => SOURCE_LABEL
          )
          result[number] = work.dictionary_sections.create!(
            sequence_number: number,
            label: "#{radical}部",
            raw_heading: nil,
            tone: nil,
            rhyme_number: nil,
            rhyme_label: nil,
            initial: nil,
            metadata: metadata
          )
        end
      end

      def create_entry!(work, section, row)
        metadata = parse_json(row["metadata_json"]).merge(
          "wfg" => true,
          "wfg_record_key" => row.fetch("record_key"),
          "wfg_source_headword" => row.fetch("source_headword"),
          "wfg_image_key" => row["image_key"],
          "wfg_is_pua_headword" => row.fetch("is_pua").to_i == 1,
          "radical" => row["radical"],
          "additional_strokes" => row["additional_strokes"],
          "additional_strokes_raw" => row["additional_strokes_raw"],
          "total_strokes" => row["total_strokes"],
          "total_strokes_raw" => row["total_strokes_raw"],
          "source_locations" => reference_metadata(row),
          "correction_source" => parse_json(row["correction_source_json"])
        ).compact

        work.dictionary_entries.create!(
          dictionary_section: section,
          corpus_document_id: nil,
          sequence_number: row.fetch("serial").to_i,
          group_sequence: nil,
          small_rime_number: nil,
          group_head: false,
          initial: nil,
          headword: row.fetch("headword"),
          definition: row["definition"].to_s.presence,
          raw_payload: row.fetch("raw_markup"),
          parser_name: PARSER_NAME,
          parser_version: PARSER_VERSION,
          source_line_start: nil,
          source_line_end: nil,
          contains_unresolved_glyph: row.fetch("is_pua").to_i == 1,
          review_required: row["additional_strokes"].nil? && row["additional_strokes_raw"].to_s.present?,
          metadata: metadata
        )
      end

      def reference_metadata(row)
        {
          "wfg_image_key" => row["image_key"],
          "volume" => row["volume"],
          "wuying" => compact_location(row["wuying_page"], row["wuying_position"]),
          "tongwen" => compact_location(row["tongwen_page"], row["tongwen_position"]),
          "punctuated" => compact_location(row["punct_page"], row["punct_position"]),
          "airitang" => compact_location(row["airitang_page"], row["airitang_position"])
        }.compact
      end

      def compact_location(page, position)
        return nil if page.nil? && position.nil?
        { "page" => page, "position" => position }.compact
      end

      def portable_character?(value)
        chars = value.to_s.each_char.to_a
        return false unless chars.one?

        codepoint = chars.first.ord
        !(codepoint.between?(0xE000, 0xF8FF) ||
          codepoint.between?(0xF0000, 0xFFFFD) ||
          codepoint.between?(0x100000, 0x10FFFD))
      end

      def find_or_create_codepoint!(glyph)
        CharacterCodepoint.find_or_create_by!(codepoint: glyph.ord) { |record| record.chr = glyph }
      end

      def parse_json(value)
        JSON.parse(value.to_s.presence || "{}")
      rescue JSON::ParserError
        {}
      end

      def import_metadata
        source = resource_metadata
        {
          "import_schema_version" => 1,
          "resource_sha256" => DictionaryCatalogue::WfgKangxiResource::SHA256,
          "mdx_sha256" => source["mdx_sha256"],
          "mdd_sha256" => source["mdd_sha256"],
          "wfg_creation_date" => source["creation_date"],
          "license" => source["license"],
          "source_notes" => {
            "base_data" => "王志攀《開放康熙》／中華開放古籍協會",
            "digital_editor" => "WFG",
            "second_edition_contributor" => "suns99",
            "primary_witness" => "康熙五十五年內府刊本（武英殿刻本）",
            "image_source" => "漢典及WFG補訂"
          }
        }
      end

      def delete_existing_work!(work)
        return unless work

        entry_ids = DictionaryEntry.where(dictionary_work_id: work.id).select(:id)
        DictionaryEntryBlock.where(dictionary_entry_id: entry_ids).delete_all if DictionaryEntryBlock.table_exists?
        DictionaryEntryAlias.where(dictionary_entry_id: entry_ids).delete_all if DictionaryEntryAlias.table_exists?
        DictionaryReading.where(dictionary_entry_id: entry_ids).delete_all
        DictionaryEntryCharacter.where(dictionary_entry_id: entry_ids).delete_all
        DictionaryReference.where(dictionary_entry_id: entry_ids).delete_all
        DictionaryEntry.where(dictionary_work_id: work.id).delete_all
        DictionarySection.where(dictionary_work_id: work.id).delete_all
        work.delete
      end

      def verify_import!(work, imported)
        expected = {
          entries: 47_043,
          sections: 214,
          aliases: resource_metadata.fetch("alias_count").to_i,
          blocks: resource_metadata.fetch("block_count").to_i,
          references: 47_043
        }
        actual = {
          entries: work.dictionary_entries.count,
          sections: work.dictionary_sections.count,
          aliases: DictionaryEntryAlias.joins(:dictionary_entry).where(dictionary_entries: { dictionary_work_id: work.id }).count,
          blocks: DictionaryEntryBlock.joins(:dictionary_entry).where(dictionary_entries: { dictionary_work_id: work.id }).count,
          references: DictionaryReference.joins(:dictionary_entry).where(dictionary_entries: { dictionary_work_id: work.id }).count
        }
        failures = expected.select { |key, value| actual.fetch(key) != value }
        return if failures.empty?

        raise "WFG Kangxi import verification failed: #{failures.map { |key, value| "#{key}=#{actual.fetch(key)} expected=#{value}" }.join(', ')}"
      end

      def result(work, status)
        {
          status: status,
          dictionary_work_id: work.id,
          corpus_work_id: work.corpus_work_id,
          title: work.title,
          entries: work.entry_count,
          sections: work.section_count,
          fingerprint: work.import_fingerprint
        }
      end
    end
  end
end
