# frozen_string_literal: true

namespace :chengyu do
  def normalized_dir
    ENV["CHENGYU_DIR"].presence || ENV["DIR"].presence || Rails.root.join("..", "wiktionary_chengyu_staging_full", "normalized").to_s
  end

  desc "Check a normalized Chengyu snapshot without changing the database. Usage: CHENGYU_DIR=/path/to/normalized bin/rails chengyu:preflight"
  task preflight: :environment do
    report = ChengyuData::Importer.new(dir: normalized_dir).preflight
    puts "[chengyu] normalized_dir=#{report[:dir]}"
    puts "[chengyu] fingerprint=#{report[:fingerprint]}"
    report[:rows].each { |file, count| puts "[chengyu] #{file}=#{count}" }
  end

  desc "Replace the Chengyu tables from a normalized snapshot. Usage: CHENGYU_DIR=/path/to/normalized bin/rails chengyu:import"
  task import: :environment do
    importer = ChengyuData::Importer.new(dir: normalized_dir)
    preflight = importer.preflight
    puts "[chengyu] importing #{preflight[:dir]}"
    puts "[chengyu] fingerprint=#{preflight[:fingerprint]}"

    result = importer.import
    puts "[chengyu] families=#{result.families}"
    puts "[chengyu] forms=#{result.forms}"
    puts "[chengyu] form_characters=#{result.form_characters}"
    puts "[chengyu] attestations=#{result.attestations}"
    puts "[chengyu] readings=#{result.readings}"
    puts "[chengyu] senses=#{result.senses}"
    puts "[chengyu] etymologies=#{result.etymologies}"
    puts "[chengyu] provenances=#{result.provenances}"
    puts "[chengyu] form_relations=#{result.form_relations}"
    puts "[chengyu] semantic_relations=#{result.semantic_relations}"
    puts "[chengyu] canonical_characters_created=#{result.characters_created}"
  end


  desc "Rebuild confirmed Chengyu source-context links from structured provenance and the cached corpus manifest"
  task rebuild_corpus_occurrences: :environment do
    result = ChengyuData::CorpusOccurrenceRebuilder.new.rebuild!
    puts "[chengyu] corpus_occurrences=#{result.occurrences}"
    puts "[chengyu] provenance_groups=#{result.provenance_groups}"
    puts "[chengyu] mapped_provenance_groups=#{result.mapped_groups}"
    puts "[chengyu] unmapped_source_titles=#{result.unmapped_source_titles.length}"
    result.unmapped_source_titles.each { |title| puts "[chengyu] unmapped_source_title=#{title}" }
  end

  desc "Verify imported Chengyu data and the Jielong game pools"
  task verify: :environment do
    counts = {
      families: Chengyu.count,
      forms: ChengyuForm.count,
      form_characters: ChengyuFormCharacter.count,
      attestations: ChengyuAttestation.count,
      readings: ChengyuReading.count,
      senses: ChengyuSense.count,
      etymologies: ChengyuEtymology.count,
      provenances: ChengyuProvenance.count,
      form_relations: ChengyuFormRelation.count,
      semantic_relations: ChengyuSemanticRelation.count,
      corpus_occurrences: defined?(ChengyuCorpusOccurrence) && ChengyuCorpusOccurrence.table_exists? ? ChengyuCorpusOccurrence.count : 0
    }

    abort "[chengyu] no Chengyu families imported" if counts[:families].zero?
    abort "[chengyu] no Chengyu forms imported" if counts[:forms].zero?

    missing_endpoints = ChengyuForm.where(first_character_codepoint_id: nil).or(ChengyuForm.where(last_character_codepoint_id: nil)).count
    standard_families = ChengyuForm.standard_game_pool.distinct.count(:chengyu_id)
    hard_families = ChengyuForm.hard_game_pool.distinct.count(:chengyu_id)
    display_form_by_family = ChengyuForm.where(is_display_form: true).pluck(:chengyu_id, :form_text).to_h
    display_without_form = Chengyu.pluck(:id, :display_form).count do |family_id, display_form|
      display_form_by_family[family_id] != display_form
    end

    counts.each { |name, count| puts "[chengyu] #{name}=#{count}" }
    puts "[chengyu] standard_game_families=#{standard_families}"
    puts "[chengyu] hard_game_families=#{hard_families}"
    puts "[chengyu] forms_without_game_endpoints=#{missing_endpoints}"
    puts "[chengyu] display_forms_missing_from_forms_table=#{display_without_form}"

    abort "[chengyu] standard game pool is empty" if standard_families.zero?
    abort "[chengyu] hard game pool is empty" if hard_families.zero?
    abort "[chengyu] one or more family display forms are missing from chengyu_forms" unless display_without_form.zero?
    if counts[:provenances].positive? && counts[:corpus_occurrences].zero?
      abort "[chengyu] no confirmed corpus source occurrences were built; run bin/rails chengyu:rebuild_corpus_occurrences after the corpus search manifest is available"
    end

    route_available = Rails.application.routes.named_routes.route_defined?(:chengyu_jielong)
    puts "[chengyu] route_chengyu_jielong=#{route_available ? 'ok' : 'MISSING — add the documented routes before going live'}"

    sample = ChengyuForm.standard_game_pool.order(:id).first
    if sample
      game = ChengyuGames::Jielong.new(mode: "standard", opponent: "adaptive", random: Random.new(1))
      result = game.start
      abort "[chengyu] Jielong start failed: #{result[:error]}" unless result[:ok]
      puts "[chengyu] Jielong smoke start=#{result.dig(:computer, :text)} next=#{result.dig(:computer, :last_character)} continuations=#{result[:continuation_count]}"
    end

    puts "[chengyu] verify ok"
  end
end
