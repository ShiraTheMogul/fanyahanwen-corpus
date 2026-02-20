# frozen_string_literal: true

# lib/tasks/guangyun.rake
#
# Usage examples:
#   bundle exec rake guangyun:import DIR="/path/to/guangyun_txts"
#   bundle exec rake guangyun:import FILES="a.txt,b.txt" SOURCE="Guangyun (Siku)" WIPE=1
#   bundle exec rake guangyun:import DIR="lib/data/guangyun" LIMIT=2000
#
namespace :guangyun do
  desc "Import Guangyun (廣韻) text files into character_properties."
  task import: :environment do
    dir = ENV["DIR"].to_s.strip
    files = ENV["FILES"].to_s.strip
    source = ENV["SOURCE"].presence || "Guangyun (Siku)"
    limit = ENV["LIMIT"].present? ? ENV["LIMIT"].to_i : nil
    wipe = ENV["WIPE"].to_s.strip == "1"

    paths =
      if files.present?
        files.split(",").map(&:strip).reject(&:empty?)
      elsif dir.present?
        Dir.glob(File.join(dir, "*.txt")).sort
      else
        default_dir = Rails.root.join("lib", "data", "guangyun").to_s
        Dir.glob(File.join(default_dir, "*.txt")).sort
      end

    if paths.empty?
      puts "[guangyun] No input files found. Provide DIR=... or FILES=..."
      exit 1
    end

    puts "[guangyun] source=#{source.inspect} files=#{paths.length} limit=#{limit.inspect} wipe=#{wipe}"
    result = Importers::GuangyunImporter.import_txts(paths, source: source, limit: limit, verbose: true, wipe: wipe)

    puts "[guangyun] done imported=#{result[:imported]} skipped=#{result[:skipped]} warnings=#{result[:warnings]}"
  end

  desc "Delete previously imported Guangyun fields for a given SOURCE (default: 'Guangyun (Siku)')."
  task purge: :environment do
    source = ENV["SOURCE"].presence || "Guangyun (Siku)"
    scope = CharacterProperty.where(source: source).where("field LIKE 'guangyun_%'")
    count = scope.count
    scope.delete_all
    puts "[guangyun] purged #{count} rows for source=#{source.inspect}"
  end
end
