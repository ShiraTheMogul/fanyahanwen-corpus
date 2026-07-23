# frozen_string_literal: true

puts "[dictionary-unification] checking normalized dictionary catalogue"

required = {
  127355 => { title: "康熙字典", mode: :sequence_range },
  79_653 => { title: "說文解字", mode: :sequence_range },
  127_386 => { title: "廣韻", mode: :tone },
  127_393 => { title: "洪武正韻", mode: :tone },
  127_372 => { title: "五音集韻", mode: :tone }
}

failures = []
required.each do |corpus_work_id, expected|
  work = DictionaryWork.find_by(corpus_work_id: corpus_work_id)
  unless work
    failures << "missing work #{expected[:title]} (#{corpus_work_id})"
    next
  end

  sections = work.dictionary_sections.order(:sequence_number).to_a
  result = DictionaryCatalogue::SectionGrouping.call(sections)
  labels = result.fetch(:groups).map { |group| group.fetch(:label) }

  puts({
    title: work.title,
    corpus_work_id: corpus_work_id,
    sections: sections.length,
    grouping_mode: result.fetch(:mode),
    dividers: labels
  }.inspect)

  failures << "#{work.title}: expected #{expected[:mode]}, got #{result.fetch(:mode)}" unless result.fetch(:mode) == expected[:mode]
end

if failures.empty?
  puts "[dictionary-unification] passed=true"
else
  warn "[dictionary-unification] passed=false"
  failures.each { |failure| warn "  - #{failure}" }
  exit 1
end
