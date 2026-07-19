# frozen_string_literal: true

namespace :atlas do
  desc "Validate every Atlas Markdown file with aliases disabled"
  task :verify_sources do
    require Rails.root.join("script", "verify_atlas_front_matter")
    require Rails.root.join("script", "verify_shang_atlas_articles")
    AtlasFrontMatterVerifier.verify!(Rails.root)
    ShangAtlasArticleVerifier.verify!(Rails.root)
  end

  desc "Rebuild the fast atlas catalogue from the existing corpus manifest"
  task rebuild_catalogue: [:environment, :verify_sources] do
    manifest = CorpusSearch::Manifest.load
    result = Atlas::CatalogueBuilder.build!(manifest: manifest)
    Atlas::Catalogue.reset!
    Atlas::EntryStore.reset!

    puts "Built #{result.entry_count} atlas polities."
    puts "Macro-regions: #{result.macro_region_count}; periods: #{result.period_count}."
    puts "Manifest rows used: #{result.document_count}; distinct works: #{result.work_count}."
    puts "Catalogue: #{result.path}"
  end

  desc "Validate the prepared atlas catalogue and all UTF-8 source files"
  task verify: [:environment, :verify_sources] do
    catalogue = Atlas::Catalogue.default
    store = Atlas::EntryStore.default
    catalogue.validate!
    store.validate!

    store.all.each do |entry|
      store.load(entry, locale: Atlas::EntryStore::SOURCE_LOCALE) if store.article_exists?(entry)
    end

    puts "Atlas verification passed."
    puts "Entries: #{store.all.length}; macro-regions: #{catalogue.macro_regions.length}."
    puts "Source: #{catalogue.source}; generated: #{catalogue.generated_at}."
  end
end
