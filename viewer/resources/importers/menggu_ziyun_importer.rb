# frozen_string_literal: true

require "csv"

module Importers
  class MengguZiyunImporter
    FIELD_MAP = {
      "小韻號" => "menggu_ziyun_xiaoyun_number",
      "韻部" => "menggu_ziyun_rhyme",
      "八思巴字" => "menggu_ziyun_phags_pa",
      "聲調" => "menggu_ziyun_tone",
      "備選異體" => "menggu_ziyun_variant",
      "釋義" => "menggu_ziyun_gloss",
      "需作調整" => "menggu_ziyun_needs_adjustment",
      "注釋" => "menggu_ziyun_notes",
      "unt擬音" => "menggu_ziyun_reconstruction",
      "unt轉寫" => "menggu_ziyun_transcription",
      "對應切韻音系音韻地位" => "menggu_ziyun_qieyun_position"
    }.freeze

    REQUIRED_HEADERS = ["字頭", "小韻號", "韻部", "八思巴字", "聲調"].freeze

    def self.import_file(path, source:, limit: nil, verbose: false, log_every: 500, wipe: false)
      full_path = expand_path(path)
      raise "File not found: #{full_path}" unless File.exist?(full_path)

      missing = missing_headers(full_path)
      raise "Missing required headers: #{missing.join(', ')}" if missing.any?

      if wipe
        CharacterProperty.where(source: source).where("field LIKE ?", "menggu_ziyun_%").delete_all
      end

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      row_no = 0
      imported = 0
      skipped_blank = 0
      skipped_non_single = 0
      skipped_duplicates = 0

      puts "[MengguZiyun] Starting: #{full_path} (source=#{source})" if verbose
      puts "[MengguZiyun] limit=#{limit.inspect} log_every=#{log_every} wipe=#{wipe}" if verbose

      ActiveRecord::Base.transaction do
        CSV.foreach(full_path, headers: true, col_sep: "	", encoding: "bom|utf-8") do |row|
          row_no += 1
          break if limit && row_no > limit

          if verbose && (row_no % log_every).zero?
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
            rate = row_no / [elapsed, 0.001].max
            puts "[MengguZiyun] row=#{row_no} imported=#{imported} skipped_blank=#{skipped_blank} skipped_non_single=#{skipped_non_single} skipped_duplicates=#{skipped_duplicates} rate=#{rate.round(0)}/s elapsed=#{elapsed.round(1)}s"
          end

          glyph = row["字頭"].to_s.strip

          if glyph.empty?
            skipped_blank += 1
            next
          end

          unless glyph.length == 1
            skipped_non_single += 1
            puts "[MengguZiyun] SKIP non-single glyph at row #{row_no}: #{glyph.inspect}" if verbose
            next
          end

          cc = find_or_create_codepoint(glyph)
          created_any = false

          FIELD_MAP.each do |tsv_header, field_name|
            value = row[tsv_header].to_s.strip
            next if value.empty?

            begin
              CharacterProperty.create!(
                character_codepoint_id: cc.id,
                source: source,
                field: field_name,
                value: value
              )
              created_any = true
            rescue ActiveRecord::RecordNotUnique
              skipped_duplicates += 1
            end
          end

          category = build_category(row)
          if category.present?
            begin
              CharacterProperty.create!(
                character_codepoint_id: cc.id,
                source: source,
                field: "menggu_ziyun_category",
                value: category
              )
              created_any = true
            rescue ActiveRecord::RecordNotUnique
              skipped_duplicates += 1
            end
          end

          xiaoyun_key = build_xiaoyun_key(row)
          if xiaoyun_key.present?
            begin
              CharacterProperty.create!(
                character_codepoint_id: cc.id,
                source: source,
                field: "menggu_ziyun_xiaoyun_key",
                value: xiaoyun_key
              )
              created_any = true
            rescue ActiveRecord::RecordNotUnique
              skipped_duplicates += 1
            end
          end

          imported += 1 if created_any
        end
      end

      {
        imported: imported,
        skipped_blank: skipped_blank,
        skipped_non_single: skipped_non_single,
        skipped_duplicates: skipped_duplicates
      }
    end

    def self.expand_path(path)
      raw = path.to_s
      return raw if Pathname.new(raw).absolute?

      Rails.root.join(raw).to_s
    end

    def self.missing_headers(path)
      CSV.open(path, headers: true, col_sep: "	", encoding: "bom|utf-8") do |csv|
        headers = csv.first&.headers || []
        return REQUIRED_HEADERS - headers
      end
    end

    def self.find_or_create_codepoint(glyph)
      codepoint = glyph.ord

      CharacterCodepoint.find_or_create_by!(codepoint: codepoint) do |cc|
        cc.chr = glyph
      end
    end

    def self.build_category(row)
      rhyme = row["韻部"].to_s.strip
      tone = row["聲調"].to_s.strip
      phags_pa = row["八思巴字"].to_s.strip

      parts = []
      parts << rhyme if rhyme.present?
      parts << tone if tone.present?
      parts << phags_pa if phags_pa.present?
      parts.join("｜")
    end

    def self.build_xiaoyun_key(row)
      num = row["小韻號"].to_s.strip
      return "" if num.empty?

      rhyme = row["韻部"].to_s.strip
      tone = row["聲調"].to_s.strip
      phags_pa = row["八思巴字"].to_s.strip

      [num, rhyme, tone, phags_pa].reject(&:blank?).join("｜")
    end
  end
end
