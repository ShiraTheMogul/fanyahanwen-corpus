# frozen_string_literal: true

namespace :atlas do
  desc "Validate typed Atlas period/polity sources and every Markdown article"
  task :verify_sources do
    require Rails.root.join("script", "verify_atlas_typed_sources")
    require Rails.root.join("script", "verify_atlas_front_matter")
    require Rails.root.join("script", "verify_shang_atlas_articles")
    require Rails.root.join("script", "verify_atlas_region_policy")
    AtlasTypedSourceVerifier.verify!(Rails.root)
    AtlasFrontMatterVerifier.verify!(Rails.root)
    ShangAtlasArticleVerifier.verify!(Rails.root)
    AtlasRegionPolicyVerifier.verify!(Rails.root)
  end


  desc "Rebuild the full clean-corpus directory index used by Atlas compilation"
  task rebuild_directory_index: :environment do
    index = CorpusSearch::DirectoryIndex.build!
    puts "Built directory index with #{index.paths.length} clean-corpus directories."
    puts "Source: #{index.source}; generated: #{index.generated_at}."
  end

  desc "Rebuild the fast typed Atlas catalogue from the existing corpus manifest"
  task rebuild_catalogue: [:environment, :verify_sources] do
    manifest = CorpusSearch::Manifest.load
    Atlas::Periodisation.reset!
    periodisation = Atlas::Periodisation.default
    periodisation.validate!
    directory_index = CorpusSearch::DirectoryIndex.load_or_build
    result = Atlas::CatalogueBuilder.build!(
      manifest: manifest,
      directory_index: directory_index,
      periodisation: periodisation
    )
    Atlas::Catalogue.reset!
    Atlas::EntryStore.reset!

    puts "Built #{result.entry_count} Atlas polities."
    puts "Macro-regions: #{result.macro_region_count}; typed periods/subperiods: #{result.period_count}."
    puts "Manifest rows used: #{result.document_count}; distinct works: #{result.work_count}."
    puts "Catalogue: #{result.path}"
  end


  desc "Verify corpus-folder polity discovery and public alias hygiene"
  task verify_discovery: :environment do
    require Rails.root.join("script", "verify_atlas_discovery_policy")
    AtlasDiscoveryPolicyVerifier.verify!
  end

  desc "Validate the prepared typed Atlas catalogue and all UTF-8 source files"
  task verify: [:environment, :verify_sources] do
    periodisation = Atlas::Periodisation.default
    catalogue = Atlas::Catalogue.default
    store = Atlas::EntryStore.default
    periodisation.validate!
    catalogue.validate!
    store.validate!

    forbidden_roots = %w[他漢文 西域漢文]
    leaked_roots = catalogue.macro_regions.flat_map { |row| Array(row["corpus_roots"]) } & forbidden_roots
    raise "Excluded corpus roots leaked into the generated Atlas catalogue: #{leaked_roots.join(', ')}" if leaked_roots.any?
    raise "西域 leaked into the generated Atlas catalogue" if catalogue.macro_region("西域")
    raise "英國 leaked into the generated Atlas catalogue" if catalogue.macro_region("英國")

    store.all.each do |entry|
      store.load(entry, locale: Atlas::EntryStore::SOURCE_LOCALE) if store.article_exists?(entry)
    end

    puts "Atlas verification passed."
    puts "Polities: #{store.all.length}; typed periods/subperiods: #{periodisation.periods.length}; macro-regions: #{catalogue.macro_regions.length}."
    puts "Source: #{catalogue.source}; generated: #{catalogue.generated_at}."
  end

  desc "Verify Atlas ordering, author splitting, continuity claims, and excluded regions"
  task verify_quality: :environment do
    require Rails.root.join("script", "verify_atlas_quality")
    AtlasQualityVerifier.verify!
  end

end
