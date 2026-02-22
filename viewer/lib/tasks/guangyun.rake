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

  desc "Import Guangyun tone/rime/category mapping by scanning 四庫全書本 '卷' plaintext files (juan_01..)."
  task import_juan_categories: :environment do
    dir = ENV["DIR"].to_s.strip
    files = ENV["FILES"].to_s.strip
    source = ENV["SOURCE"].presence || "Guangyun (Siku)"
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
      puts "[guangyun:juan] No input files found. Provide DIR=... or FILES=..."
      exit 1
    end

    puts "[guangyun:juan] source=#{source.inspect} files=#{paths.length} wipe=#{wipe}"
    result = Importers::GuangyunSikuJuanCategoriesImporter.import_txts(paths, source: source, wipe: wipe, verbose: true)
    puts "[guangyun:juan] done inserted=#{result[:inserted]} skipped_missing_cc=#{result[:skipped_missing_cc]} warnings=#{result[:warnings]}"
  end

  desc "Fix known bad rime name that was accidentally parsed as a header (rename to 肴)."
  task fix_bad_rime_hyao: :environment do
    source = ENV["SOURCE"].presence || "Guangyun (Siku)"
    bad = "經文字曰其琴瑟亦用此字作"

    scope_rhyme = CharacterProperty.where(source: source, field: "guangyun_rhyme", value: bad)
    scope_cat = CharacterProperty.where(source: source, field: "guangyun_category").where("value LIKE ?", "%#{bad}%")

    puts "[guangyun:fix] source=#{source.inspect}"
    puts "[guangyun:fix] rhyme_rows=#{scope_rhyme.count} category_rows=#{scope_cat.count}"

    fixed = 0
    ActiveRecord::Base.transaction do
      scope_rhyme.find_each do |row|
        row.update!(value: "肴")
        fixed += 1
      end

      scope_cat.find_each do |row|
        row.update!(value: row.value.to_s.sub(bad, "肴"))
        fixed += 1
      end
    end

    puts "[guangyun:fix] updated_rows=#{fixed}"
  end

end
