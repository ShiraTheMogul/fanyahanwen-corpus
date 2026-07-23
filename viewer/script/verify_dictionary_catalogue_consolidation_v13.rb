#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../config/environment"
require "json"

phase = ENV.fetch("PHASE", "pre").to_s
unless %w[pre post].include?(phase)
  warn "PHASE must be pre or post"
  exit 2
end

WORKS = {
  127_355 => { title: "御定康熙字典", sections: 214, minimum_entries: 46_000 },
  79_653 => { title: "說文解字", sections: 540, minimum_entries: 9_800 },
  127_386 => { title: "廣韻", minimum_sections: 1, minimum_entries: 25_000 }
}.freeze

LEGACY_TABLES = %w[
  kangxi_radicals
  character_radical_memberships
  shuowen_components
  character_component_memberships
].freeze

LEGACY_ROUTES = %w[
  dictionary_radicals
  dictionary_radical
  dictionary_radical_chars
  dictionary_components
  dictionary_component
  dictionary_component_chars
  dictionary_guangyun
  dictionary_guangyun_category
  dictionary_guangyun_category_chars
].freeze

blockers = []
warnings = []
puts "Dictionary catalogue consolidation v13"
puts "======================================"
puts "Phase: #{phase}"
puts "Mode: ZERO-WRITE"
puts

works = {}
WORKS.each do |corpus_work_id, requirements|
  work = DictionaryWork.find_by(corpus_work_id: corpus_work_id)
  if work.nil?
    blockers << "missing normalized dictionary corpus_work_id=#{corpus_work_id}"
    next
  end

  actual_sections = work.dictionary_sections.count
  actual_entries = work.dictionary_entries.count
  works[corpus_work_id] = work

  blockers << "#{work.title}: stored section_count=#{work.section_count}, actual=#{actual_sections}" unless work.section_count == actual_sections
  blockers << "#{work.title}: stored entry_count=#{work.entry_count}, actual=#{actual_entries}" unless work.entry_count == actual_entries
  blockers << "#{work.title}: sections=#{actual_sections}, expected=#{requirements[:sections]}" if requirements[:sections] && actual_sections != requirements[:sections]
  blockers << "#{work.title}: no usable sections" if requirements[:minimum_sections] && actual_sections < requirements[:minimum_sections]
  blockers << "#{work.title}: entries=#{actual_entries}, minimum=#{requirements[:minimum_entries]}" if actual_entries < requirements[:minimum_entries]

  puts format(
    "%-12s corpus_work_id=%-7d sections=%-4d entries=%-7d",
    work.title,
    corpus_work_id,
    actual_sections,
    actual_entries
  )
end

kangxi = works[127_355]
shuowen = works[79_653]

if kangxi
  radical_sections = kangxi.dictionary_sections.order(:sequence_number).to_a
  missing_metadata = radical_sections.count do |section|
    metadata = section.metadata.is_a?(Hash) ? section.metadata : {}
    metadata["radical"].blank? || metadata["stroke_count"].nil?
  end
  blockers << "Kangxi normalized sections missing radical metadata=#{missing_metadata}" unless missing_metadata.zero?
  puts "Kangxi section metadata complete: #{missing_metadata.zero?}"
end

krs_rows = CharacterProperty.where(field: "kRSUnicode").where.not(value: [nil, ""]).pluck(:value)
parsed_krs_memberships = krs_rows.sum do |value|
  value.to_s.split(/\s+/).count { |token| DictionaryCatalogue::KangxiStructure.parse_token(token) }
end
blockers << "No parseable kRSUnicode memberships remain" if parsed_krs_memberships.zero?
puts "kRSUnicode source rows: #{krs_rows.length}"
puts "Parseable radical memberships: #{parsed_krs_memberships}"

connection = ActiveRecord::Base.connection
legacy_presence = LEGACY_TABLES.to_h { |table| [table, connection.data_source_exists?(table)] }
legacy_presence.each { |table, present| puts "legacy table #{table}: #{present ? 'present' : 'absent'}" }

if phase == "pre"
  legacy_presence.each do |table, present|
    blockers << "expected pre-migration table #{table} is absent" unless present
  end

  if legacy_presence["kangxi_radicals"] && kangxi
    legacy_count = connection.select_value("SELECT COUNT(*) FROM kangxi_radicals").to_i
    blockers << "legacy Kangxi radical count=#{legacy_count}, expected=214" unless legacy_count == 214

    legacy_rows = connection.select_all("SELECT number, radical, stroke_count FROM kangxi_radicals ORDER BY number").to_a
    sections = kangxi.dictionary_sections.order(:sequence_number).index_by(&:sequence_number)
    mismatches = legacy_rows.count do |row|
      section = sections[row.fetch("number").to_i]
      metadata = section&.metadata.is_a?(Hash) ? section.metadata : {}
      section.nil? ||
        metadata["radical"].to_s != row.fetch("radical").to_s ||
        metadata["stroke_count"].to_i != row.fetch("stroke_count").to_i
    end
    blockers << "Kangxi radical metadata parity mismatches=#{mismatches}" unless mismatches.zero?
    puts "Kangxi radical metadata parity mismatches: #{mismatches}"
  end

  if legacy_presence["character_radical_memberships"]
    legacy_memberships = connection.select_value("SELECT COUNT(*) FROM character_radical_memberships").to_i
    blockers << "kRSUnicode parsed memberships=#{parsed_krs_memberships}, legacy rows=#{legacy_memberships}" unless parsed_krs_memberships == legacy_memberships
    puts "Kangxi membership parity: source=#{parsed_krs_memberships} legacy=#{legacy_memberships}"
  end

  if legacy_presence["shuowen_components"] && shuowen
    legacy_components = connection.select_all("SELECT number, glyph FROM shuowen_components ORDER BY number").to_a
    sections = shuowen.dictionary_sections.order(:sequence_number).index_by(&:sequence_number)
    mismatches = legacy_components.count do |row|
      section = sections[row.fetch("number").to_i]
      metadata = section&.metadata.is_a?(Hash) ? section.metadata : {}
      imported_glyph = metadata["legacy_component_glyph"] || metadata["catalogue_component_glyph"]
      section.nil? || imported_glyph.to_s != row.fetch("glyph").to_s
    end
    blockers << "Shuowen component metadata parity mismatches=#{mismatches}" unless mismatches.zero?
    puts "Shuowen component metadata parity mismatches: #{mismatches}"
  end

  if legacy_presence["character_component_memberships"] && shuowen
    generic_missing = connection.select_value(<<~SQL.squish).to_i
      SELECT COUNT(*)
      FROM character_component_memberships legacy
      WHERE NOT EXISTS (
        SELECT 1
        FROM dictionary_entry_characters links
        JOIN dictionary_entries entries
          ON entries.id = links.dictionary_entry_id
         AND entries.dictionary_work_id = #{connection.quote(shuowen.id)}
        JOIN dictionary_sections sections
          ON sections.id = entries.dictionary_section_id
         AND sections.sequence_number = legacy.component_number
        WHERE links.character_codepoint_id = legacy.character_codepoint_id
      )
    SQL
    blockers << "Shuowen legacy memberships missing from normalized catalogue=#{generic_missing}" unless generic_missing.zero?
    puts "Shuowen memberships missing from normalized catalogue: #{generic_missing}"
  end
else
  legacy_presence.each do |table, present|
    blockers << "retired table #{table} still exists" if present
  end

  routes_text = Rails.root.join("config", "routes.rb").read
  remaining_routes = LEGACY_ROUTES.select { |route_name| routes_text.include?("as: :#{route_name}") }
  blockers << "legacy route names remain: #{remaining_routes.join(', ')}" if remaining_routes.any?
  puts "Legacy routes remaining: #{remaining_routes.length}"

  deleted_files = Rails.root.join("DELETE_FILES.txt")
  warnings << "DELETE_FILES.txt is still in the viewer root; it may be removed after review" if deleted_files.exist?
end

puts
puts "Blockers: #{blockers.length}"
blockers.each { |blocker| puts "  BLOCKER: #{blocker}" }
puts "Warnings: #{warnings.length}"
warnings.each { |warning| puts "  WARNING: #{warning}" }
puts "Database writes: 0"
puts "Passed: #{blockers.empty?}"

exit(blockers.empty? ? 0 : 1)
