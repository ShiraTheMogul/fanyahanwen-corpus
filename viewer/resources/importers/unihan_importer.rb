# app/services/importers/unihan_importer.rb
module Importers
  class UnihanImporter
    # Import a Unihan-style TSV file:
    #   U+3400 <tab> kField <tab> value
    #
    # fields: optional array of field names to keep (nil = keep all)
    # limit: optional integer; import only first N data lines (for testing)
    # verbose/log_every: progress logging
    def self.import_file(path, source:, fields: nil, limit: nil, verbose: false, log_every: 50_000)
      full_path = Rails.root.join(path).to_s
      raise "File not found: #{full_path}" unless File.exist?(full_path)

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      line_no = 0
      imported = 0
      skipped  = 0

      puts "[UnihanImporter] Starting: #{path} (source=#{source})" if verbose
      puts "[UnihanImporter] fields=#{fields.inspect} limit=#{limit.inspect} log_every=#{log_every}" if verbose

      ActiveRecord::Base.transaction do
        File.foreach(full_path, encoding: "UTF-8") do |line|
          line_no += 1

          if verbose && (line_no % log_every).zero?
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
            rate = (line_no / [elapsed, 0.001].max)
            puts "[UnihanImporter] line=#{line_no} imported=#{imported} skipped=#{skipped} rate=#{rate.round(0)}/s elapsed=#{elapsed.round(1)}s"
          end

          next if line.start_with?("#") || line.strip.empty?

          uplus, field, value = line.split("\t", 3)
          unless uplus && field && value
            skipped += 1
            next
          end

          value = value.strip
          next if value.empty?
          next if fields && !fields.include?(field)

          hex = uplus.delete_prefix("U+")
          codepoint = hex.to_i(16)

          chr = codepoint.chr(Encoding::UTF_8)

          cc = CharacterCodepoint.find_or_create_by!(codepoint: codepoint) do |row|
            row.chr = chr
          end

          # Unique index handles dedupe.
          CharacterProperty.find_or_create_by!(
            character_codepoint_id: cc.id,
            source: source,
            field: field,
            value: value
          )

          imported += 1
          break if limit && imported >= limit
        end
      end

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
      puts "[UnihanImporter] DONE lines=#{line_no} imported=#{imported} skipped=#{skipped} elapsed=#{elapsed.round(1)}s" if verbose

      { imported: imported, skipped: skipped }
    end
  end
end
