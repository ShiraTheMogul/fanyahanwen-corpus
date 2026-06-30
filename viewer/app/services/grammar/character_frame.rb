# frozen_string_literal: true

require "erb"

module Grammar
  # Read-only reference data for the side panel on a single-character grammar hub.
  # It consumes the same CharacterCodepoint, CharacterProperty, VariantMapping,
  # PronunciationRegistry and Kangxi radical data used by the dictionary.
  class CharacterFrame
    attr_reader :character, :properties, :variants, :pronunciation_sections,
                :shuowen_entry, :kangxi_entry, :radical_membership, :radical

    def self.for(headword)
      return nil unless headword.to_s.each_char.count == 1
      return nil unless headword.to_s.match?(/\A\p{Han}\z/)

      new(headword.to_s).tap(&:load!)
    end

    def initialize(headword)
      @headword = headword
      @properties = []
      @variants = []
      @pronunciation_sections = []
    end

    def load!
      @character = CharacterCodepoint.find_by(codepoint: @headword.ord)
      return self unless @character

      @properties = CharacterProperty
        .where(character_codepoint_id: @character.id)
        .order(:field, :source, :value)
        .to_a

      definition_properties = properties
      if no_dictionary_definitions? && base_character
        definition_properties += CharacterProperty
          .where(character_codepoint_id: base_character.id)
          .where(field: %w[shuowen_entry kangxi_gloss])
          .order(:field, :source, :value)
          .to_a
      end

      @shuowen_entry = first_value(definition_properties, source: "Shuowen Jiezi", field: "shuowen_entry")
      @kangxi_entry = first_value(definition_properties, source: "Kangxi", field: "kangxi_gloss")
      @kangxi_entry ||= definition_properties.find { |property| property.field.to_s == "kangxi_gloss" }&.value.to_s.strip.presence

      pronunciation_rows = properties.select { |property| PronunciationRegistry.pronunciation_field?(property.field) }
      @pronunciation_sections = PronunciationRegistry.pronunciation_sections(pronunciation_rows)
      @variants = load_variants
      @radical_membership = CharacterRadicalMembership
        .where(character_codepoint_id: @character.id)
        .order(:additional_strokes, :radical_number)
        .first
      @radical = KangxiRadical.find_by(number: @radical_membership.radical_number) if @radical_membership

      self
    end

    def present?
      character.present?
    end

    def glyph
      character&.chr || @headword
    end

    def codepoint_label
      return nil unless character

      format("U+%04X", character.codepoint)
    end

    def dictionary_path
      "/characters/#{ERB::Util.url_encode(glyph)}"
    end

    private

    def base_character
      return @base_character if defined?(@base_character)

      base_cp = VariantMapping.where(variant_codepoint: @character.codepoint).order(:id).pick(:base_codepoint)
      base_cp ||= cedict_traditional_codepoint
      @base_character =
        if base_cp.present? && base_cp != @character.codepoint
          CharacterCodepoint.find_by(codepoint: base_cp)
        end
    end

    def cedict_traditional_codepoint
      value = properties.find do |property|
        property.source.to_s == "CC-CEDICT" &&
          %w[cedict_trad ccdict_trad].include?(property.field.to_s)
      end&.value.to_s.strip
      value.length == 1 ? value.ord : nil
    end

    def no_dictionary_definitions?
      properties.none? do |property|
        %w[shuowen_entry kangxi_gloss].include?(property.field.to_s) &&
          property.value.to_s.strip.present?
      end
    end

    def first_value(rows, source:, field:)
      row = rows.find do |property|
        property.source.to_s == source && property.field.to_s == field && property.value.to_s.strip.present?
      end
      row&.value.to_s.strip.presence
    end

    def load_variants
      values = {}

      VariantMapping.where(base_codepoint: @character.codepoint).order(:variant_codepoint).find_each do |mapping|
        values[mapping.variant_codepoint] ||= mapping.source.to_s.presence || "VariantMapping"
      end

      VariantMapping.where(variant_codepoint: @character.codepoint).order(:base_codepoint).find_each do |mapping|
        values[mapping.base_codepoint] ||= mapping.source.to_s.presence || "VariantMapping"
      end

      properties.each do |property|
        if property.field.to_s == "kCompatibilityVariant"
          extract_codepoints(property.value).each { |codepoint| values[codepoint] ||= property.source.to_s.presence || "Unihan_Variants" }
        elsif %w[kSemanticVariant kSpecializedSemanticVariant].include?(property.field.to_s)
          extract_codepoints(property.value).each { |codepoint| values[codepoint] ||= property.source.to_s.presence || "Unihan_Variants" }
        elsif property.source.to_s == "CC-CEDICT" && %w[cedict_trad ccdict_trad cedict_simp ccdict_simp].include?(property.field.to_s)
          property.value.to_s.each_char.select { |char| char.match?(/\p{Han}/) }.each do |char|
            values[char.ord] ||= "CC-CEDICT"
          end
        end
      end

      values.delete(@character.codepoint)
      rows = CharacterCodepoint.where(codepoint: values.keys).index_by(&:codepoint)
      values.keys.sort.filter_map do |codepoint|
        row = rows[codepoint]
        next unless row

        {
          codepoint: codepoint,
          glyph: row.chr,
          label: format("%s (U+%04X)", row.chr, codepoint),
          source: values[codepoint]
        }
      end
    end

    def extract_codepoints(raw)
      text = raw.to_s
      codepoints = text.scan(/U\+[0-9A-Fa-f]{4,6}/).map { |token| token.delete_prefix("U+").to_i(16) }
      if codepoints.empty?
        codepoints = text.each_char.select { |char| char.match?(/\p{Han}/) }.map(&:ord)
      end
      codepoints.uniq
    end
  end
end
