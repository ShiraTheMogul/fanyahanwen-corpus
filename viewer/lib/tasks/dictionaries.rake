# frozen_string_literal: true

require Rails.root.join("lib/dictionary_import/ready_jsonl").to_s
require Rails.root.join("resources/importers/dictionary_catalogue_importer").to_s

namespace :dictionaries do
  desc "Validate a reviewed dictionary JSONL against the live corpus without writing to the database"
  task plan: :environment do
    file = ENV.fetch("FILE")
    corpus_root = ENV.fetch("CORPUS_ROOT", Rails.root.join("..", "corpus").to_s)
    output = ENV.fetch("OUTPUT", Rails.root.join("tmp/dictionary_import/database_import_plan").to_s)
    expected = ENV["EXPECTED"]&.to_i
    edition_label = ENV["EDITION_LABEL"]
    source_label = ENV.fetch("SOURCE_LABEL", "Fanya Hanwen Corpus")

    dataset = DictionaryImport::ReadyJsonl.new(
      entries_path: file,
      corpus_root: corpus_root,
      expected_entries: expected
    ).load!

    dataset.write_plan(
      output_dir: output,
      edition_label: edition_label,
      source_label: source_label
    )

    summary = dataset.summary
    puts "[dictionaries:plan] passed=#{summary['passed']} title=#{summary['dictionary_title'].inspect} entries=#{summary['entries']} sections=#{summary['sections']} blockers=#{summary['blockers']}"
    puts "[dictionaries:plan] output=#{Pathname.new(output).expand_path}"
    abort "Dictionary database plan blocked. Review blockers.csv." unless dataset.valid?
  end

  desc "Import one reviewed dictionary JSONL into the generic dictionary tables"
  task import: :environment do
    file = ENV.fetch("FILE")
    corpus_root = ENV.fetch("CORPUS_ROOT", Rails.root.join("..", "corpus").to_s)
    expected = ENV["EXPECTED"]&.to_i
    edition_label = ENV["EDITION_LABEL"]
    source_label = ENV.fetch("SOURCE_LABEL", "Fanya Hanwen Corpus")
    replace = ENV["REPLACE"].to_s == "1"
    log_every = ENV.fetch("LOG_EVERY", "500").to_i

    result = Importers::DictionaryCatalogueImporter.import!(
      entries_path: file,
      corpus_root: corpus_root,
      expected_entries: expected,
      edition_label: edition_label,
      source_label: source_label,
      replace: replace,
      verbose: true,
      log_every: log_every
    )

    puts "[dictionaries:import] #{result.inspect}"
  end

  desc "Verify stored row counts for one imported corpus work ID"
  task verify: :environment do
    corpus_work_id = Integer(ENV.fetch("CORPUS_WORK_ID"))
    work = DictionaryWork.find_by!(corpus_work_id: corpus_work_id)

    actual = {
      sections: work.dictionary_sections.count,
      entries: work.dictionary_entries.count,
      readings: DictionaryReading.joins(:dictionary_entry).where(dictionary_entries: { dictionary_work_id: work.id }).count,
      entry_characters: DictionaryEntryCharacter.joins(:dictionary_entry).where(dictionary_entries: { dictionary_work_id: work.id }).count,
      references: DictionaryReference.joins(:dictionary_entry).where(dictionary_entries: { dictionary_work_id: work.id }).count
    }

    expected = {
      sections: work.section_count,
      entries: work.entry_count,
      readings: work.reading_count,
      entry_characters: work.entry_character_count,
      references: work.reference_count
    }

    puts "[dictionaries:verify] title=#{work.title.inspect} corpus_work_id=#{work.corpus_work_id}"
    actual.each do |name, count|
      puts "[dictionaries:verify] #{name}=#{count} expected=#{expected[name]}"
    end

    failures = actual.select { |name, count| count != expected[name] }
    abort "Dictionary verification failed: #{failures.inspect}" if failures.any?

    puts "[dictionaries:verify] passed=true"
  end
end
