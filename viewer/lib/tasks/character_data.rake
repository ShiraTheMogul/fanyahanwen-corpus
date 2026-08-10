# frozen_string_literal: true

namespace :character_data do
  desc "Check the character-learning models and parsers without importing data"
  task preflight_learning: :environment do
    CharacterStructure.where(system: "ids").limit(0).load
    CharacterInputCode.limit(0).load
    CharacterStructureComponent.limit(0).load

    samples = [
      "北\t⿲二丨匕(.,T);⿰⿱⿰一丨一匕(H);⿲二丨匕(th,wh)\n",
      "一\t#(H)(.);{一}#(T)(t)\n",
      "𫜺\t⿱山田\n",
      "𬺢\t⿱一八\n",
      "𳎰\t⿰日月\n",
      "⺌\t⿰丶リ  ⿻丨丷\n",
      "〣\t⿰丨〢  ⿰〢丨;⿴〢丨\n",
      "◜\t#(Qd)\n",
      "の\t#(kana)\n",
      "한\t#(hangul)\n"
    ]
    parser = Ids::SourceRowParser.new
    samples.each do |sample|
      row = parser.parse(sample)
      raise "IDS source-row preflight failed for #{sample.inspect}" unless row&.candidates&.any?
      row.candidates.each { |candidate| Ids::Parser.parse(candidate.expression) }
    end

    missing_ids_levels = Ids::Importer::LEVELS.reject { |level| Ids::Importer::DEFAULT_URLS.key?(level) }
    raise "Missing yi-bai/ids source presets: #{missing_ids_levels.join(', ')}" if missing_ids_levels.any?

    required_sources = %w[cangjie5 wubi86 moran]
    missing_sources = required_sources.reject { |system_id| CharacterData::SourceCatalogue::SOURCES.key?(system_id) }
    raise "Missing character input source presets: #{missing_sources.join(', ')}" if missing_sources.any?

    required_core = ["〇", "〢", "𝍠", "の", "コ", "한", "ᄀ"]
    missing_core = required_core.reject { |glyph| CharacterData::CoreRepertoireSeeder.all_codepoints.include?(glyph.ord) }
    raise "Missing core character repertoire samples: #{missing_core.join(' ')}" if missing_core.any?

    difficult = Ids::DifficultComponents.entries
    raise "Difficult-component catalogue unexpectedly small" if difficult.length < 500
    raise "Difficult-component catalogue missing 𦥑" unless Ids::DifficultComponents.unique_glyphs.include?("𦥑")

    puts "[character-data] preflight ok: Rails models, indexable character repertoire, Unicode-17 Han classification, IDS parser, difficult-component catalogue, and source catalogue loaded"
  end

  desc "Ensure Kana, Hangul, Suzhou numerals, counting rods, and tally marks exist in the canonical character registry"
  task seed_core_repertoire: :environment do
    result = CharacterData::CoreRepertoireSeeder.new.seed
    groups = result.by_repertoire.map { |name, count| "#{name}=#{count}" }.join(" ")
    puts "[character-data] core repertoire: characters=#{result.characters} created=#{result.created} existing=#{result.existing} #{groups}"
  end

  desc "Seed zi.tools-style difficult IDS components into the canonical registry and dictionary properties"
  task seed_difficult_components: :environment do
    result = CharacterData::DifficultComponentSeeder.new.seed
    puts "[character-data] difficult components: memberships=#{result.memberships} characters=#{result.characters} created=#{result.created_characters} properties=#{result.properties}"
  end

  desc "Diagnose yi-bai/ids parsing without writing data. Usage: LEVEL=lv0|lv1|lv2 [FILE=...] [SAMPLES=20]"
  task diagnose_ids: :environment do
    level = ENV.fetch("LEVEL", "lv1")
    sample_limit = ENV.fetch("SAMPLES", "20").to_i
    result = Ids::Diagnostic.new(sample_limit: sample_limit).run(
      level: level,
      path: ENV["FILE"].presence,
      url: ENV["URL"].presence
    )

    puts "[ids-diagnostic] #{level}: lines=#{result.lines} ignored=#{result.ignored} rows=#{result.rows} candidates=#{result.candidates} source_errors=#{result.source_errors} candidate_errors=#{result.candidate_errors} empty_rows=#{result.empty_rows}"

    {
      "SOURCE ROW ERRORS" => result.source_error_samples,
      "IDS CANDIDATE ERRORS" => result.candidate_error_samples,
      "ROWS WITHOUT IDS CANDIDATES" => result.empty_row_samples
    }.each do |heading, samples|
      next if samples.empty?

      puts
      puts "=== #{heading} ==="
      samples.each do |sample|
        puts
        puts "line #{sample.line_number}: #{sample.error}"
        puts sample.source
      end
    end

    if result.clean?
      puts "[ids-diagnostic] clean: every parsed source row has IDS data and every candidate is understood"
    else
      abort "[ids-diagnostic] NOT CLEAN: do not import this level yet"
    end
  end

  desc "Import yi-bai/ids strictly. Usage: bin/rails character_data:import_ids LEVEL=lv0|lv1|lv2 [FILE=...] [REPLACE=1]"
  task import_ids: :environment do
    level = ENV.fetch("LEVEL", "lv1")
    result = Ids::Importer.new.import(
      level: level,
      path: ENV["FILE"].presence,
      url: ENV["URL"].presence,
      replace: ENV["REPLACE"].to_s == "1"
    )
    puts "[ids] lines=#{result.lines} rows=#{result.rows} candidates=#{result.candidates} structures=#{result.structures} characters=#{result.characters} source_errors=#{result.source_errors} candidate_errors=#{result.candidate_errors} empty_rows=#{result.empty_rows}"
  end

  desc "Import single-character codes from a RIME dictionary or a curated preset. Usage: SYSTEM=wubi86|cangjie5|moran"
  task import_rime_codes: :environment do
    system_id = ENV["SYSTEM"].to_s.strip
    abort "Provide SYSTEM=cangjie5, SYSTEM=wubi86, SYSTEM=moran, or a custom system id." if system_id.empty?

    result = CharacterData::RimeCodeImporter.new.import(
      system_id: system_id,
      path: ENV["FILE"].presence,
      url: ENV["URL"].presence,
      source: ENV["SOURCE"].presence,
      source_version: ENV["VERSION"].presence,
      format: ENV["FORMAT"].presence,
      kind: ENV["KIND"].presence,
      replace: ENV["REPLACE"].to_s == "1"
    )
    puts "[rime-codes] system=#{system_id} lines=#{result.lines} tables=#{result.tables} codes=#{result.codes} characters=#{result.characters} skipped=#{result.skipped}"
  end

  desc "Import the curated character-data set used by the dictionary and games"
  task import_learning_defaults: :environment do
    seed = CharacterData::CoreRepertoireSeeder.new.seed
    puts "[character-data] core repertoire: characters=#{seed.characters} created=#{seed.created} existing=#{seed.existing}"

    difficult = CharacterData::DifficultComponentSeeder.new.seed
    puts "[character-data] difficult components: memberships=#{difficult.memberships} characters=#{difficult.characters} created=#{difficult.created_characters} properties=#{difficult.properties}"

    Ids::Importer::LEVELS.each do |level|
      diagnostic = Ids::Diagnostic.new(sample_limit: 5).run(level: level)
      unless diagnostic.clean?
        abort "[ids] #{level} diagnostic failed before import: source_errors=#{diagnostic.source_errors} candidate_errors=#{diagnostic.candidate_errors} empty_rows=#{diagnostic.empty_rows}. Run character_data:diagnose_ids LEVEL=#{level}."
      end

      result = Ids::Importer.new.import(level: level, replace: ENV["REPLACE"].to_s == "1")
      puts "[ids] #{level}: structures=#{result.structures} characters=#{result.characters} source_errors=#{result.source_errors} candidate_errors=#{result.candidate_errors} empty_rows=#{result.empty_rows}"
    end

    %w[cangjie5 wubi86 moran].each do |system_id|
      result = CharacterData::RimeCodeImporter.new.import(system_id: system_id, replace: ENV["REPLACE"].to_s == "1")
      puts "[rime-codes] #{system_id}: tables=#{result.tables} codes=#{result.codes} characters=#{result.characters} skipped=#{result.skipped}"
    end
  end
end
