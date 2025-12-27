# CSV is part of the Ruby standard library, but I still need to require it.
require "csv"

module Importers
  class VariantMappingImporter
    # A "class method" (self.import_file) means I call it like so:
    # Importers::VariantMappingImporter.import_file(...)
    def self.import_file(path, source:, limit: nil, verbose: false, log_every: 50_000)
      # Rails.root is the root folder of the Rails app.
      # join(path) turns "variant_mapping.csv" into "/full/path/to/app/variant_mapping.csv".
      full_path = Rails.root.join(path).to_s

      # If the file doesn't exist, crash early with a clear message.
      raise "File not found: #{full_path}" unless File.exist?(full_path)

      # CLOCK_MONOTONIC is a timer that won't jump if the system clock changes.
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Counters for reporting. I need to know if the script is alive!
      row_no   = 0
      imported = 0
      skipped  = 0

      puts "[Variant] Starting: #{full_path} (source=#{source})" if verbose
      puts "[Variant] limit=#{limit.inspect} log_every=#{log_every}" if verbose

      # A transaction groups DB changes together.
      # If an exception is raised inside, the DB changes are rolled back (undone).
      ActiveRecord::Base.transaction do
        # "bom|utf-8" tells Ruby: "if there's a BOM, strip it".
        CSV.foreach(full_path, headers: true, encoding: "bom|utf-8") do |row|
          row_no += 1

          # If limit is set (not nil) and we've passed it, stop looping.
          break if limit && row_no > limit

          # Log progress every log_every rows.
          if verbose && (row_no % log_every).zero?
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time
            rate = row_no / [elapsed, 0.001].max
            puts "[Variant] row=#{row_no} imported=#{imported} skipped=#{skipped} rate=#{rate.round(0)}/s elapsed=#{elapsed.round(1)}s"
          end

          # Pull values out of the CSV row by header name.
          # These come out as Strings (or nil if missing).
          variant_chr = row["variant"]
          base_chr    = row["base"]

          # strip removes whitespace/newlines around the text if it appears for some reason
          # Safe navigation (&.) means: "only call strip if not nil".
          variant_chr = variant_chr&.strip
          base_chr    = base_chr&.strip

          # Skip empty rows.
          if variant_chr.nil? || variant_chr.empty? || base_chr.nil? || base_chr.empty?
            skipped += 1
            next # "next" means: skip the rest of this loop iteration, go to the next row
          end

          # .ord converts a one-character String to its Unicode codepoint integer.
          # Example: "反".ord => 21453
          variant_codepoint = variant_chr.ord
          base_codepoint    = base_chr.ord

          # Insert-or-update style:
          # - find_or_initialize_by finds a row, OR builds a new one without saving yet.
          mapping = VariantMapping.find_or_initialize_by(variant_codepoint: variant_codepoint)

          # Always set these fields (if the row already existed, this updates it in memory).
          mapping.base_codepoint = base_codepoint
          mapping.source         = source

          # save! writes to the database.
          # "!" means raise an error if validation fails.
          mapping.save!

          imported += 1
        end
      end

      # Return summary hash
      { imported: imported, skipped: skipped }
    end
  end
end
