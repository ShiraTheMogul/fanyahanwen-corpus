# app/services/importers/bulk_text_importer.rb
module Importers
  class BulkTextImporter
    def self.import_all(root: "resources/unihan", glob: "*.txt", verbose: true, log_every: 50_000)
      root_path = Rails.root.join(root)
      files = Dir.glob(root_path.join(glob)).sort

      puts "[BulkTextImporter] root=#{root_path}"
      puts "[BulkTextImporter] files=#{files.length}"

      total_imported = 0
      total_skipped  = 0

      files.each_with_index do |full_path, idx|
        rel = Pathname.new(full_path).relative_path_from(Rails.root).to_s
        source = File.basename(full_path, ".txt")

        puts "\n[BulkTextImporter] (#{idx + 1}/#{files.length}) Importing #{rel} source=#{source}"

        result = Importers::UnihanImporter.import_file(
          rel,
          source: source,
          fields: nil,
          limit: nil,
          verbose: verbose,
          log_every: log_every
        )

        total_imported += result[:imported].to_i
        total_skipped  += result[:skipped].to_i
        puts "[BulkTextImporter] done #{rel} imported=#{result[:imported]} skipped=#{result[:skipped]}"
      rescue => e
        puts "[BulkTextImporter] ERROR in #{rel}: #{e.class}: #{e.message}"
      end

      puts "\n[BulkTextImporter] ALL DONE total_imported=#{total_imported} total_skipped=#{total_skipped}"
      { imported: total_imported, skipped: total_skipped, files: files.length }
    end
  end
end
