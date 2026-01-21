# frozen_string_literal: true

namespace :unihan do
  desc "Import a single Unihan field (e.g. kIDS) from resources/unihan/*.txt. Usage: FIELD=kIDS SOURCE=Unihan_DictionaryLikeData"
  task import_field: :environment do
    field = ENV["FIELD"].to_s.strip
    abort "Provide FIELD=..., e.g. FIELD=kIDS" if field.empty?

    root = ENV["ROOT"].presence || "resources/unihan"
    source = ENV["SOURCE"].presence # optional override

    # If SOURCE is not provided, auto-detect which file contains the field.
    rel_path =
      if source.present?
        File.join(root, "#{source}.txt")
      else
        Importers::UnihanFieldLocator.find_file_with_field(root_dir: root, field: field)
      end

    abort "[unihan] Could not find any *.txt in #{root} containing field #{field.inspect}." unless rel_path

    source ||= File.basename(rel_path, ".txt")

    puts "[unihan] Importing field=#{field.inspect} from #{rel_path} (source=#{source})"
    Importers::UnihanImporter.import_file(
      rel_path,
      source: source,
      fields: [field],
      verbose: true,
      log_every: 200_000
    )
  end

  desc "Show a quick count of CharacterProperty rows by field (top 40)"
  task field_counts: :environment do
    rows = CharacterProperty.group(:field).order(Arel.sql("COUNT(*) DESC")).limit(40).count
    puts "[unihan] Top fields in character_properties:"
    rows.each do |k, v|
      puts "  #{k}: #{v}"
    end
  end
end
