# frozen_string_literal: true

namespace :menggu_ziyun do
  desc "Import Menggu Ziyun TSV data into character_properties."
  task import: :environment do
    path = ENV["PATH"].to_s.strip
    source = ENV["SOURCE"].presence || "Nk2028/menggu-ziyun-data, 2025"
    limit = ENV["LIMIT"].present? ? ENV["LIMIT"].to_i : nil
    wipe = ENV["WIPE"].to_s.strip == "1"
    verbose = ENV["VERBOSE"].to_s.strip == "1"

    if path.empty?
      default_path = Rails.root.join("lib", "data", "menggu_ziyun", "data.tsv")
      path = default_path.to_s
    end

    puts "[menggu_ziyun] source=#{source.inspect} path=#{path.inspect} limit=#{limit.inspect} wipe=#{wipe} verbose=#{verbose}"

    result = Importers::MengguZiyunImporter.import_file(
      path,
      source: source,
      limit: limit,
      verbose: verbose,
      wipe: wipe
    )

    puts "[menggu_ziyun] done imported=#{result[:imported]} skipped_blank=#{result[:skipped_blank]} skipped_non_single=#{result[:skipped_non_single]} skipped_duplicates=#{result[:skipped_duplicates]}"
  end

  desc "Delete previously imported Menggu Ziyun fields for a given SOURCE."
  task purge: :environment do
    source = ENV["SOURCE"].presence || "(Nk2028/menggu-ziyun-data, 2025)"
    scope = CharacterProperty.where(source: source).where("field LIKE ?", "menggu_ziyun_%")
    count = scope.count
    scope.delete_all
    puts "[menggu_ziyun] purged #{count} rows for source=#{source.inspect}"
  end
end
