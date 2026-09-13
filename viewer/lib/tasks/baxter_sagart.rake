# frozen_string_literal: true

namespace :baxter_sagart do
  BS2014_PDF = "resources/baxter_sagart/BaxterSagartOCbyGSR2014-09-20.pdf"
  BS2006_PDF = "resources/baxter_sagart/PUB_1570754349.pdf"

  desc "Report what is in the corpus now for Baxter & Sagart, without changing anything"
  task audit: :environment do
    require Rails.root.join("resources/importers/baxter_sagart_importer").to_s

    report = Importers::BaxterSagartImporter.audit
    puts "[baxter_sagart] bs2014_oc values                 : #{report[:values]}"
    puts "[baxter_sagart] with a voiceless sonorant (l̥ ŋ̊) : #{report[:with_voiceless_sonorant]}"
    puts "[baxter_sagart] with Cyrillic schwa U+04D9       : #{report[:with_cyrillic_schwa]}"
    puts "[baxter_sagart] with Latin schwa U+0259          : #{report[:with_latin_schwa]}"
    puts

    if report[:healthy]
      puts "[baxter_sagart] healthy."
    else
      puts "[baxter_sagart] DAMAGED. The source marks 229 reconstructions with a"
      puts "[baxter_sagart] voiceless-sonorant ring; 78 of them become a different"
      puts "[baxter_sagart] reconstruction once it is lost — 湯 傷 觴 愓 (*l̥aŋ) merge"
      puts "[baxter_sagart] into 昜 陽 揚 楊 鍚 颺 (*laŋ). Re-import to repair:"
      puts
      puts "    bin/rails baxter_sagart:reimport_oc"
    end
  end

  desc "Re-import Baxter & Sagart 2014 from the PDF, replacing the existing values"
  task reimport_oc: :environment do
    require Rails.root.join("resources/importers/baxter_sagart_importer").to_s

    before = Importers::BaxterSagartImporter.audit
    puts "[baxter_sagart] before: #{before.inspect}"

    # replace: true because find_or_create_by! cannot correct a row that is
    # already present under a different, wrong value — it would simply add the
    # right one alongside the wrong one.
    Importers::BaxterSagartImporter.import_bs2014_pdf(path: BS2014_PDF, replace: true)

    after = Importers::BaxterSagartImporter.audit
    puts "[baxter_sagart] after:  #{after.inspect}"
    puts

    # The reading-system slot cache is keyed on row count, which a value
    # correction need not change. Clear it so the inventories are rebuilt from
    # the repaired data rather than served stale.
    cache = Rails.root.join(CharacterQuery::SlotIndex::CACHE_DIR)
    if cache.directory?
      removed = Dir.glob(cache.join("*.json.gz")).each { |f| File.delete(f) }.size
      puts "[baxter_sagart] cleared #{removed} cached slot index file(s)"
    end

    abort "[baxter_sagart] still damaged — see the warnings above" unless after[:healthy]
    puts "[baxter_sagart] repaired."
  end

  desc "Import Baxter 2006 Middle Chinese (ASCII; unaffected by the extraction defects)"
  task import_2006_mc: :environment do
    require Rails.root.join("resources/importers/baxter_sagart_importer").to_s

    map = Importers::BaxterSagartImporter.import_bs2014_pdf(path: BS2014_PDF, verbose: false)
    Importers::BaxterSagartImporter.import_baxter2006_mc_pdf(path: BS2006_PDF, gsr_to_codepoint: map)
  end
end
