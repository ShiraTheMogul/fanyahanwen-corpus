# frozen_string_literal: true

namespace :dictionaries do
  namespace :wfg_kangxi do
    desc "Validate the bundled WFG Kangxi resource without changing the database"
    task plan: :environment do
      require Rails.root.join("resources/importers/wfg_kangxi_importer").to_s
      plan = Importers::WfgKangxiImporter.plan
      puts "[wfg-kangxi:plan] #{plan.inspect}"
    end

    desc "Import the bundled WFG Kangxi resource into the normalized dictionary catalogue"
    task import: :environment do
      require Rails.root.join("resources/importers/wfg_kangxi_importer").to_s
      result = Importers::WfgKangxiImporter.import!(
        replace: ENV["REPLACE"].to_s == "1",
        verbose: true,
        log_every: [ENV.fetch("LOG_EVERY", "1000").to_i, 1].max
      )
      puts "[wfg-kangxi:import] #{result.inspect}"
    end

    desc "Verify the stored WFG Kangxi dictionary against the bundled resource"
    task verify: :environment do
      require Rails.root.join("resources/importers/wfg_kangxi_importer").to_s
      work = DictionaryWork.find_by!(corpus_work_id: Importers::WfgKangxiImporter::WORK_ID, corpus_edition_id: nil)
      resource = DictionaryCatalogue::WfgKangxiResource
      abort "WFG Kangxi resource failed integrity checks." unless resource.available?

      metadata = resource.metadata_hash
      counts = {
        entries: work.dictionary_entries.count,
        sections: work.dictionary_sections.count,
        readings: DictionaryReading.joins(:dictionary_entry).where(dictionary_entries: { dictionary_work_id: work.id }).count,
        entry_characters: DictionaryEntryCharacter.joins(:dictionary_entry).where(dictionary_entries: { dictionary_work_id: work.id }).count,
        aliases: DictionaryEntryAlias.joins(:dictionary_entry).where(dictionary_entries: { dictionary_work_id: work.id }).count,
        blocks: DictionaryEntryBlock.joins(:dictionary_entry).where(dictionary_entries: { dictionary_work_id: work.id }).count,
        references: DictionaryReference.joins(:dictionary_entry).where(dictionary_entries: { dictionary_work_id: work.id }).count
      }

      expected = {
        entries: metadata.fetch("occurrence_count").to_i,
        sections: 214,
        readings: work.reading_count,
        entry_characters: work.entry_character_count,
        aliases: metadata.fetch("alias_count").to_i,
        blocks: metadata.fetch("block_count").to_i,
        references: metadata.fetch("occurrence_count").to_i
      }

      failures = counts.select { |name, count| count != expected.fetch(name) }
      puts "[wfg-kangxi:verify] title=#{work.title.inspect} fingerprint=#{work.import_fingerprint}"
      counts.each { |name, count| puts "[wfg-kangxi:verify] #{name}=#{count} expected=#{expected.fetch(name)}" }

      # Serial 24335 is the known WFG text-key error: the source image and
      # independent Kangxi witnesses show 𦛢 although the MDX key is 腘.
      repaired = work.dictionary_entries.find_by(sequence_number: 24_335)
      unless repaired&.headword == "𦛢" && repaired.dictionary_entry_aliases.where(kind: "WFG數位字頭", form: "腘").exists?
        failures[:digital_key_rectification] = "missing"
      end

      fallback = work.dictionary_entries.find_by(sequence_number: 10_286)
      failures[:empty_headword_fallback] = "missing" unless fallback&.headword == "㩮"

      abort "WFG Kangxi verification failed: #{failures.inspect}" if failures.any?
      puts "[wfg-kangxi:verify] passed=true"
    end
  end
end
