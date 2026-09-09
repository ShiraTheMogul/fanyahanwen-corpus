# frozen_string_literal: true

# Adds character-standard and dictionary-alias equivalence to the generic
# dictionary lookup. This remains generic: WFG contributes aliases as data,
# while CharacterStandards contributes the site's normal script conversions.
module DictionaryCatalogueKangxi
  private

  def lookup_entries(query)
    value = query.to_s
    base = @work.dictionary_entries
      .includes(:dictionary_section, :dictionary_readings, :dictionary_entry_characters)
      .order(:sequence_number)

    if value.each_char.one?
      equivalents = dictionary_lookup_equivalents(value)
      entry_ids = []

      entry_ids.concat(
        DictionaryEntryCharacter
          .joins(:dictionary_entry)
          .where(dictionary_entries: { dictionary_work_id: @work.id }, glyph: equivalents)
          .pluck(:dictionary_entry_id)
      )
      entry_ids.concat(
        DictionaryEntryAlias
          .joins(:dictionary_entry)
          .where(dictionary_entries: { dictionary_work_id: @work.id }, form: equivalents)
          .pluck(:dictionary_entry_id)
      ) if DictionaryEntryAlias.table_exists?
      entry_ids.concat(base.where(headword: equivalents).pluck(:id))

      base.where(id: entry_ids.uniq).limit(self.class::LOOKUP_LIMIT).to_a
    else
      ids = base.where(headword: value).pluck(:id)
      if DictionaryEntryAlias.table_exists?
        ids.concat(
          DictionaryEntryAlias
            .joins(:dictionary_entry)
            .where(dictionary_entries: { dictionary_work_id: @work.id }, form: value)
            .pluck(:dictionary_entry_id)
        )
      end
      base.where(id: ids.uniq).limit(self.class::LOOKUP_LIMIT).to_a
    end
  end

  def dictionary_lookup_equivalents(character)
    seen = { character => true }
    queue = [character]

    # Conversion is deliberately bounded. Running every selectable standard on
    # newly found forms for two rounds reaches common Simplified/Traditional,
    # regional, Kangxi and 古文 forms without turning dictionary lookup into an
    # unbounded graph walk.
    2.times do
      seeds = queue.dup
      queue.clear
      seeds.each do |seed|
        CharacterStandards.selectable_modes.each do |mode|
          converted = CharacterStandards.convert(seed, mode).to_s
          next unless converted.each_char.one?
          next if seen[converted]

          seen[converted] = true
          queue << converted
        rescue CharacterStandards::ConversionUnavailable
          next
        end
      end
      break if queue.empty?
    end

    seen.keys
  rescue StandardError
    [character]
  end
end
