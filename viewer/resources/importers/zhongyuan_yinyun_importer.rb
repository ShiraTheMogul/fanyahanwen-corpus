# frozen_string_literal: true

require "csv"
module Importers
  class ZhongyuanYinyunImporter
    FIELD_MAP = {
      "小韻" => "zhongyuan_yinyun_xiaoyun",
      "聲母" => "zhongyuan_yinyun_initial",
      "韻母" => "zhongyuan_yinyun_final",
      "聲調" => "zhongyuan_yinyun_tone",
      "楊耐思" => "zhongyuan_yinyun_yang_naisi",
      "寧繼福" => "zhongyuan_yinyun_ning_jifu",
      "薛鳳生(音位)" => "zhongyuan_yinyun_xue_fengsheng",
      "unt(音位)" => "zhongyuan_yinyun_unt_phonemic",
      "unt" => "zhongyuan_yinyun_unt",
      "釋義" => "zhongyuan_yinyun_gloss",
      "校註" => "zhongyuan_yinyun_notes"
    }.freeze

    REQUIRED_HEADERS = ["小韻", "字", "聲母", "韻母", "聲調"].freeze

    def self.import_file(path, source:, limit: nil, verbose: false, log_every: 500, wipe: false)
      full_path = expand_path(path)
      raise "File not found: #{full_path}" unless File.exist?(full_path)

      missing = missing_headers(full_path)
      raise "Missing required headers: #{missing.join(', ')}" if missing.any?

      if wipe
        CharacterProperty.where(source: source).where("field LIKE ?", "zhongyuan_yinyun_%").delete_all
      end

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      row_no = 0
      imported_rows = 0
      imported_glyphs = 0
      skipped_blank_rows = 0
      skipped_blank_glyphs = 0
      skipped_duplicates = 0

      puts "[ZhongyuanYinyun] Starting: #{full_path} (source=#{source})" if verbose
      puts "[ZhongyuanYinyun] limit=#{limit.inspect} log_every=#{log_every} wipe=#{wipe}" if verbose

      ActiveRecord::Base.transaction do
        CSV.foreach(full_path, headers: true, col_sep: "\t", encoding: "bom|utf-8") do |row|
          row_no += 1
          break if limit && row_no > limit

          if verbose && (row_no % log_every).zero?
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
            rate = row_no / [elapsed, 0.001].max
            puts "[ZhongyuanYinyun] row=#{row_no} imported_rows=#{imported_rows} imported_glyphs=#{imported_glyphs} skipped_blank_rows=#{skipped_blank_rows} skipped_blank_glyphs=#{skipped_blank_glyphs} skipped_duplicates=#{skipped_duplicates} rate=#{rate.round(0)}/s elapsed=#{elapsed.round(1)}s"
          end

          glyphs = normalize_glyphs(row["字"])
          if glyphs.empty?
            skipped_blank_rows += 1
            next
          end

          row_created_any = false

          glyphs.each do |glyph|
            if glyph.blank?
              skipped_blank_glyphs += 1
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
                  field: "zhongyuan_yinyun_category",
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
                  field: "zhongyuan_yinyun_xiaoyun_key",
                  value: xiaoyun_key
                )
                created_any = true
              rescue ActiveRecord::RecordNotUnique
                skipped_duplicates += 1
              end
            end

            if created_any
              imported_glyphs += 1
              row_created_any = true
            end
          end

          imported_rows += 1 if row_created_any
        end
      end

      {
        imported_rows: imported_rows,
        imported_glyphs: imported_glyphs,
        skipped_blank_rows: skipped_blank_rows,
        skipped_blank_glyphs: skipped_blank_glyphs,
        skipped_duplicates: skipped_duplicates
      }
    end

    def self.expand_path(path)
      raw = path.to_s
      return raw if Pathname.new(raw).absolute?

      Rails.root.join(raw).to_s
    end

    def self.missing_headers(path)
      CSV.open(path, headers: true, col_sep: "\t", encoding: "bom|utf-8") do |csv|
        headers = csv.first&.headers || []
        return REQUIRED_HEADERS - headers
      end
    end

    def self.normalize_glyphs(raw)
      raw.to_s.each_char.reject { |char| char.strip.empty? }.uniq
    end

    def self.find_or_create_codepoint(glyph)
      codepoint = glyph.ord

      CharacterCodepoint.find_or_create_by!(codepoint: codepoint) do |cc|
        cc.chr = glyph
      end
    end

    def self.build_category(row)
      initial = row["聲母"].to_s.strip
      final = row["韻母"].to_s.strip
      tone = row["聲調"].to_s.strip

      [initial, final, tone].reject(&:blank?).join("｜")
    end

    def self.build_xiaoyun_key(row)
      xiaoyun = row["小韻"].to_s.strip
      return "" if xiaoyun.empty?

      initial = row["聲母"].to_s.strip
      final = row["韻母"].to_s.strip
      tone = row["聲調"].to_s.strip

      [xiaoyun, initial, final, tone].reject(&:blank?).join("｜")
    end
  end
end
