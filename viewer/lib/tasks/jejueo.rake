# frozen_string_literal: true

namespace :jejueo do
  SOURCE_BOOK = "Yang, Yang & O’Grady 2020"
  SOURCE_DICTIONARY = "Jejueo-English Basic Dictionary"

  DIRECT_HANGUL = "reading.koreanic.jejueo.hangul"
  DIRECT_ROMANISATION = "reading.koreanic.jejueo.source_romanisation"
  COMPOUND_HANGUL = "reading.koreanic.jejueo.compound_hangul"
  COMPOUND_ROMANISATION = "reading.koreanic.jejueo.compound_source_romanisation"
  COMPOUND_ATTESTATION = "reading.koreanic.jejueo.compound_attestation"

  DIRECT_READINGS = {
    "一" => [["일", "il"]],
    "二" => [["이", "i"]],
    "三" => [["ᄉᆞᆷ", "sawm"], ["삼", "sam"]],
    "四" => [["ᄉᆞ", "saw"]],
    "五" => [["오", "o"]],
    "六" => [["육", "yug"]],
    "七" => [["칠", "chil"]],
    "八" => [["팔", "pal"]],
    "九" => [["구", "gu"]],
    "十" => [["십", "sib"]],
    "百" => [["백", "beg"]],
    "千" => [["천", "cheon"]],
    "朝" => [["ᄌᆞ", "chaw"]]
  }.freeze

  COMPOUNDS = [
    ["濟州語", "제주어", "jejueo", SOURCE_BOOK,
     [["濟", "제", "je"], ["州", "주", "ju"], ["語", "어", "eo"]]],
    ["濟州島", "제주도", "jejudo", SOURCE_BOOK,
     [["濟", "제", "je"], ["州", "주", "ju"], ["島", "도", "do"]]],
    ["濟州道", "제주도", "jejudo", SOURCE_BOOK,
     [["濟", "제", "je"], ["州", "주", "ju"], ["道", "도", "do"]]],
    ["漢拏山", "할락산", "hallagsan", SOURCE_DICTIONARY,
     [["漢", "할", "hal"], ["拏", "락", "lag"], ["山", "산", "san"]]],
    ["三姓穴", "삼성혈", "Samseonghyeol", SOURCE_BOOK,
     [["三", "삼", "sam"], ["姓", "성", "seong"], ["穴", "혈", "hyeol"]]]
  ].freeze

  desc "Inspect or import reviewed Sino-Jejueo character readings; dry-run unless APPLY=1"
  task import_readings: :environment do
    apply = ENV["APPLY"].to_s == "1"
    rows = []

    DIRECT_READINGS.each do |character, readings|
      readings.each do |hangul, romanisation|
        rows << [character, SOURCE_BOOK, DIRECT_HANGUL, hangul]
        rows << [character, SOURCE_BOOK, DIRECT_ROMANISATION, romanisation]
      end
    end

    COMPOUNDS.each do |hanja, hangul, romanisation, source, segments|
      attestation = [hanja, hangul, romanisation].join(" · ")

      segments.each do |character, segment_hangul, segment_romanisation|
        rows << [character, source, COMPOUND_HANGUL, segment_hangul]
        rows << [character, source, COMPOUND_ROMANISATION, segment_romanisation]
        rows << [character, source, COMPOUND_ATTESTATION, attestation]
      end
    end

    rows.uniq!
    missing = rows.map(&:first).uniq.reject { |character| CharacterCodepoint.exists?(chr: character) }
    abort "Missing CharacterCodepoint rows: #{missing.join(', ')}" if missing.any?

    puts "[jejueo] reviewed properties: #{rows.length}"
    puts "[jejueo] corrections: 三 ᄉᆞᆸ→ᄉᆞᆷ; 三 note 십→삼; 漢拏山 hallasan→hallagsan"
    puts "[jejueo] native numeral 싯 is excluded because this task imports Sino-Jejueo readings"

    unless apply
      puts "[jejueo] dry run only; add APPLY=1 to write"
      rows.each { |character, source, field, value| puts [character, source, field, value].join("\t") }
      next
    end

    inserted = 0
    existing = 0

    CharacterProperty.transaction do
      rows.each do |character, source, field, value|
        codepoint = CharacterCodepoint.find_by!(chr: character)
        property = CharacterProperty.find_or_initialize_by(
          character_codepoint: codepoint,
          source: source,
          field: field,
          value: value
        )

        if property.new_record?
          property.save!
          inserted += 1
        else
          existing += 1
        end
      end
    end

    puts "[jejueo] inserted=#{inserted} already_present=#{existing}"
  end
end
