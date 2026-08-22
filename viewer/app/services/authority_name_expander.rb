# frozen_string_literal: true

require "set"

# Expands an explicitly supplied Han name into mechanical search aliases.
# Generated aliases are search keys only; they never merge authority records.
class AuthorityNameExpander
  MAX_NAME_LENGTH = 12
  MAX_FORMS_PER_CHARACTER = 12
  MAX_DERIVED_FORMS = 96
  SAFE_COMBINATION_SOURCES = Set.new(%w[
    opencc_simplified_traditional
    opencc_japanese_shinjitai
  ]).freeze

  Form = Data.define(:name, :derivation)

  def initialize(registry: CorpusSearch::CharacterEquivalenceRegistry.new(level: "broad"))
    @registry = registry
    @explanation_cache = {}
  end

  def expand(name)
    source = name.to_s.strip
    chars = source.each_char.to_a
    return [] if chars.empty? || chars.length > MAX_NAME_LENGTH
    return [] unless chars.all? { |char| han_char?(char) }

    options = chars.map { |char| character_forms(char) }
    derived = {}

    chars.each_index do |index|
      options[index].drop(1).each do |replacement|
        variant = chars.dup
        variant[index] = replacement
        record_form!(derived, source, variant.join, [[chars[index], replacement]])
        break if derived.length >= MAX_DERIVED_FORMS
      end
      break if derived.length >= MAX_DERIVED_FORMS
    end

    # Historical/lexicographic variant graphs can be very broad and sometimes
    # transitive. Keep every useful single-position substitution, but only form
    # multi-character Cartesian combinations from the tightly controlled OpenCC
    # simplified/traditional and Japanese shinjitai mappings. Otherwise a
    # four-character ruler name can manufacture hundreds of unlikely spellings
    # and make automatic annotation noisier rather than more tolerant.
    if derived.length < MAX_DERIVED_FORMS
      combination_options = chars.each_with_index.map do |original, index|
        options[index].select do |replacement|
          replacement == original || safe_combination_replacement?(original, replacement)
        end
      end

      partials = [["", []]]
      chars.each_with_index do |original, index|
        next_partials = []
        partials.each do |prefix, changes|
          combination_options[index].each do |replacement|
            next_changes = replacement == original ? changes : changes + [[original, replacement]]
            next_partials << [prefix + replacement, next_changes]
            break if next_partials.length >= MAX_DERIVED_FORMS * 2
          end
          break if next_partials.length >= MAX_DERIVED_FORMS * 2
        end
        partials = next_partials
      end

      partials.each do |variant, changes|
        next if changes.empty?

        record_form!(derived, source, variant, changes)
        break if derived.length >= MAX_DERIVED_FORMS
      end
    end

    derived.map { |variant, derivation| Form.new(name: variant, derivation: derivation) }
  end

  private

  def character_forms(character)
    forms = @registry.forms_for(character).to_a
    forms.delete(character)
    ordered = forms.sort_by do |form|
      sources = mapping_sources(character, form)
      [mapping_priority(sources), form]
    end
    [character, *ordered].first(MAX_FORMS_PER_CHARACTER)
  end

  def mapping_priority(sources)
    return 0 if sources.include?("opencc_simplified_traditional")
    return 1 if sources.include?("opencc_japanese_shinjitai")
    return 2 if (sources & %w[taiwan_moe zetian_script]).any?

    3
  end

  def record_form!(output, source, variant, changes)
    return if variant == source || output.key?(variant)

    sources = changes.flat_map { |left, right| mapping_sources(left, right) }.uniq
    output[variant] = derivation_label(sources)
  end

  def mapping_sources(left, right)
    return [] if left == right

    @explanation_cache[[left, right]] ||= begin
      explanation = @registry.explanation(query_character: left, source_character: right)
      Array(explanation&.fetch("mapping_sources", nil)).map(&:to_s)
    end
  end

  def safe_combination_replacement?(left, right)
    sources = mapping_sources(left, right)
    sources.any? && sources.all? { |source| SAFE_COMBINATION_SOURCES.include?(source) }
  end

  def derivation_label(sources)
    labels = []
    labels << "opencc_simplified_traditional" if sources.include?("opencc_simplified_traditional")
    labels << "opencc_japanese_shinjitai" if sources.include?("opencc_japanese_shinjitai")
    labels << "historical_variant" if (sources & %w[taiwan_moe zetian_script]).any?
    labels << "broad_equivalence" if labels.empty?
    labels.join("+")
  end

  def han_char?(character)
    character.to_s.match?(/\p{Han}/)
  end
end
