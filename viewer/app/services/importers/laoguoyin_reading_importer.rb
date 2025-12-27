require "csv"

module Importers
  class LaoguoyinReadingImporter
    def self.import_file(path, source:, limit: nil, verbose: false, log_every: 100)
      full_path = Rails.root.join(path).to_s
      raise "File not found: #{full_path}" unless File.exist?(full_path)

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      row_no   = 0
      imported = 0
      skipped  = 0

      puts "[Laoguoyin] Starting: #{full_path} (source=#{source})" if verbose
      puts "[Laoguoyin] limit=#{limit.inspect} log_every=#{log_every}" if verbose

      ActiveRecord::Base.transaction do
        CSV.foreach(full_path, headers: true, encoding: "bom|utf-8") do |row|
          row_no += 1
          break if limit && row_no > limit

          if verbose && (row_no % log_every).zero?
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
            rate = row_no / [elapsed, 0.001].max
            puts "[Laoguoyin] row=#{row_no} imported=#{imported} skipped=#{skipped} rate=#{rate.round(0)}/s elapsed=#{elapsed.round(1)}s"
          end

          chr      = row["character"]&.strip
          laoguo   = row["laoguoyin"]&.strip
          zhuyin   = row["zhuyin"]&.strip
          ipa      = row["ipa"]&.strip

          if chr.nil? || chr.empty? || laoguo.nil? || laoguo.empty?
            skipped += 1
            next
          end

          # Determine codepoint (prefer explicit codepoint column if present)
          codepoint =
            if row["codepoint"] && !row["codepoint"].strip.empty?
              cp = row["codepoint"].strip
              if cp.start_with?("U+")
                cp.delete_prefix("U+").to_i(16)
              else
                cp.to_i
              end
            else
              chr.ord
            end

          # Ensure CharacterCodepoint row exists
          cc = CharacterCodepoint.find_or_initialize_by(codepoint: codepoint)
          cc.chr = chr
          cc.save! if cc.new_record? || cc.changed?

          # Upsert reading (unique by char + laoguoyin + source)
          reading = LaoguoyinReading.find_or_initialize_by(
            character_codepoint_id: cc.id,
            laoguoyin: laoguo,
            source: source
          )

          reading.zhuyin = zhuyin if zhuyin && !zhuyin.empty?
          reading.ipa    = ipa    if ipa && !ipa.empty?

          reading.save!
          imported += 1
        end
      end

      { imported: imported, skipped: skipped }
    end
  end
end
