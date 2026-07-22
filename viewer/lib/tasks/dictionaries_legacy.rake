# frozen_string_literal: true

require Rails.root.join("resources/importers/legacy_structured_dictionary_catalogue_importer").to_s

namespace :dictionaries do
  desc "Import Kangxi or Shuowen structured legacy data into the unified dictionary catalogue"
  task import_legacy: :environment do
    kind = ENV.fetch("KIND")
    default = kind == "kangxi" ? Rails.root.join("resources/kangxi/kx_full.xlsx") : Rails.root.join("resources/fanyahanwen_research/shuowen.xlsx")
    result = Importers::LegacyStructuredDictionaryCatalogueImporter.import!(
      kind: kind,
      source_path: ENV["FILE"].presence || default,
      replace: ENV["REPLACE"].to_s == "1",
      verbose: true
    )
    puts "[dictionaries:import_legacy] #{result.inspect}"
  end
end
