# frozen_string_literal: true

# Rake tasks to run supplemental script imports.
#
# Pattern you can reuse:
#   bin/rails "namespace:task KEY=/path/to/file.csv OTHER=value"
#
# In Rake, ENV[...] reads those KEY=VALUE pairs.
# That lets you keep the tasks stable while swapping input files.

namespace :supplements do
  def required_env!(key)
    v = ENV[key]
    if v.nil? || v.strip.empty?
      raise "Missing required ENV var #{key}. Example: #{key}=/path/to/file"
    end
    v
  end

  desc "Import Church Slavonic transcription characters (CSV)"
  task import_slavonic: :environment do
    path = required_env!("SLAVONIC_CSV")
    source = ENV["SLAVONIC_SOURCE"] || "slavonic_wiki"

    importer = Importers::SupplementalScriptsImporter.new
    importer.import_slavonic_csv!(path, source: source)

    puts "[supplements] imported Slavonic CSV from #{path} (source=#{source})"
  end

  desc "Import Zetian Script (則天文字) variants and context (CSV)"
  task import_zetian: :environment do
    path = required_env!("ZETIAN_CSV")
    mapping_source = ENV["ZETIAN_MAPPING_SOURCE"] || "Zetian Script (則天文字)"
    prop_source = ENV["ZETIAN_PROP_SOURCE"] || "zetian"

    importer = Importers::SupplementalScriptsImporter.new
    importer.import_zetian_csv!(path, mapping_source: mapping_source, prop_source: prop_source)

    puts "[supplements] imported Zetian CSV from #{path} (mapping_source=#{mapping_source}, prop_source=#{prop_source})"
  end

  desc "Import Manyogana hiragana etymology table (XLSX)"
  task import_manyogana_hiragana: :environment do
    path = required_env!("MANYO_HIRA_XLSX")
    field = ENV["MANYO_HIRA_FIELD"] || "jp_manyogana_hiragana_etym"
    source = ENV["MANYO_HIRA_SOURCE"] || "manyogana_wiki"

    importer = Importers::SupplementalScriptsImporter.new
    importer.import_manyogana_etym_xlsx!(path, field: field, source: source)

    puts "[supplements] imported Manyogana hiragana etym from #{path} (field=#{field}, source=#{source})"
  end

  desc "Import Manyogana katakana etymology table (XLSX)"
  task import_manyogana_katakana: :environment do
    path = required_env!("MANYO_KATA_XLSX")
    field = ENV["MANYO_KATA_FIELD"] || "jp_manyogana_katakana_etym"
    source = ENV["MANYO_KATA_SOURCE"] || "manyogana_wiki"

    importer = Importers::SupplementalScriptsImporter.new
    importer.import_manyogana_etym_xlsx!(path, field: field, source: source)

    puts "[supplements] imported Manyogana katakana etym from #{path} (field=#{field}, source=#{source})"
  end

  desc "Import Manyogana mora table (XLSX) (requires lookup XLSX for kana mapping)"
  task import_manyogana_mora: :environment do
    path = required_env!("MANYO_MORA_XLSX")
    lookup = required_env!("KANA_LOOKUP_XLSX")
    field = ENV["MANYO_MORA_FIELD"] || "jp_manyogana_mora_table"
    source = ENV["MANYO_MORA_SOURCE"] || "manyogana_wiki"

    importer = Importers::SupplementalScriptsImporter.new
    importer.import_manyogana_mora_table_xlsx!(path, kana_lookup_xlsx: lookup, field: field, source: source)

    puts "[supplements] imported Manyogana mora table from #{path} (lookup=#{lookup}, field=#{field}, source=#{source})"
  end

  desc "Import Shakuon kana (借音仮名) (CSV)"
  task import_shakuon: :environment do
    path = required_env!("SHAKUON_CSV")
    field = ENV["SHAKUON_FIELD"] || "jp_shakuon_kana"
    source = ENV["SHAKUON_SOURCE"] || "shakuon_wiki"

    importer = Importers::SupplementalScriptsImporter.new
    importer.import_kana_borrowing_csv!(path, field: field, source: source)

    puts "[supplements] imported Shakuon CSV from #{path} (field=#{field}, source=#{source})"
  end

  desc "Import Shakkun kana (借訓仮名) (CSV)"
  task import_shakkun: :environment do
    path = required_env!("SHAKKUN_CSV")
    field = ENV["SHAKKUN_FIELD"] || "jp_shakkun_kana"
    source = ENV["SHAKKUN_SOURCE"] || "shakkun_wiki"

    importer = Importers::SupplementalScriptsImporter.new
    importer.import_kana_borrowing_csv!(path, field: field, source: source)

    puts "[supplements] imported Shakkun CSV from #{path} (field=#{field}, source=#{source})"
  end

  desc "Import all supplemental datasets (requires all relevant ENV vars)"
  task import_all: :environment do
    Rake::Task["supplements:import_slavonic"].invoke
    Rake::Task["supplements:import_zetian"].invoke
    Rake::Task["supplements:import_manyogana_hiragana"].invoke
    Rake::Task["supplements:import_manyogana_katakana"].invoke
    Rake::Task["supplements:import_manyogana_mora"].invoke
    Rake::Task["supplements:import_shakuon"].invoke
    Rake::Task["supplements:import_shakkun"].invoke
  end
end
