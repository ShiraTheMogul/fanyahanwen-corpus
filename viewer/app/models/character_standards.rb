# frozen_string_literal: true

# Display-only character-standard conversions.
#
# Corpus files and database values remain untouched. A view asks this object for
# a transformed copy of the text and renders that copy only.
module CharacterStandards
  MODES = %i[
    original
    traditional
    simplified
    singapore_1969
    wu_zhao
    shinjitai
    erjian_1
    erjian_2
  ].freeze

  ERJIAN_MODES = %i[erjian_1 erjian_2].freeze
  ZETIAN_SOURCE = "Zetian Script (則天文字)"

  # The corpus stores multiple attested forms for a few 則天文字. For a
  # single selectable display standard we use the familiar/common form shown
  # in modern reference tables; all other single-valued mappings come straight
  # from variant_mappings.
  ZETIAN_PREFERRED_VARIANTS = {
    "照" => "曌",
    "天" => "𠀑",
    "月" => "囝",
    "君" => "𠁈",
    "年" => "𠦚",
    "載" => "𠧋",
    "授" => "𥢓",
    "證" => "𨭻"
  }.freeze

  # Some corpus mappings were entered against a simplified base character.
  # Accept the corresponding traditional form as input as well, and vice versa
  # where the stored base is traditional.
  ZETIAN_BASE_ALIASES = {
    "國" => "国",
    "聖" => "圣",
    "應" => "应",
    "证" => "證",
    "载" => "載"
  }.freeze

  SHINJITAI_REVERSE_PREFERENCES = {
    "鹽" => "塩",
    "畫" => "画",
    "鋪" => "舗",
    "莊" => "荘",
    "鬥" => "闘",
    "驅" => "駆"
  }.freeze

  module_function

  def allowed_modes
    MODES
  end

  def erjian_mode?(mode)
    ERJIAN_MODES.include?(normalise_mode(mode))
  end

  # OpenCC is the normal Traditional/Simplified conversion engine. Its
  # dictionaries handle phrase-level ambiguity that a one-character lookup
  # cannot. If the native binding cannot be loaded or conversion fails, fall
  # back to the corpus' Unihan variant data so display rendering still works.
  def traditional(text)
    opencc_script_convert(text, :s2t, :traditional)
  end

  def simplified(text)
    opencc_script_convert(text, :t2s, :simplified)
  end

  def opencc_script_convert(text, config, fallback_mode)
    value = text.to_s
    return value if value.empty?

    converted = opencc_convert(value, config)
    return converted unless converted.nil?

    unihan_script_convert(value, fallback_mode)
  end

  def opencc_convert(text, config)
    # Gemfile uses require: false deliberately: a missing runtime OpenCC
    # library must not stop Rails booting before the Unihan fallback can run.
    require "opencc" unless defined?(::OpenCC)
    ::OpenCC.public_send(config, text.to_s)
  rescue LoadError, StandardError
    nil
  end

  def unihan_script_convert(text, mode)
    value = text.to_s
    return value if value.empty?

    map = unihan_script_map(mode)
    return value if map.empty?

    value.each_char.map { |character| map.fetch(character, character) }.join
  rescue StandardError
    value
  end

  def unihan_script_map(mode)
    field =
      case normalise_mode(mode)
      when :simplified
        "kSimplifiedVariant"
      when :traditional
        "kTraditionalVariant"
      end
    return {} if field.nil?

    Rails.cache.fetch("unihan_script_map:v1:#{field}") do
      rows = CharacterProperty.where(source: "Unihan_Variants", field: field)
                              .pluck(:character_codepoint_id, :value)

      ids = rows.map(&:first).uniq
      id_to_character = CharacterCodepoint.where(id: ids).pluck(:id, :chr).to_h

      rows.each_with_object({}) do |(character_id, raw_value), map|
        source = id_to_character[character_id]
        next if source.blank?

        token = raw_value.to_s.strip.split(/\s+/).first
        target = unihan_token_to_character(token)
        map[source] = target unless target.nil?
      end
    end
  rescue StandardError
    {}
  end

  def unihan_token_to_character(token)
    value = token.to_s.strip
    return nil if value.empty?

    if value.match?(/\AU\+[0-9A-Fa-f]{4,6}\z/)
      return value.delete_prefix("U+").to_i(16).chr(Encoding::UTF_8)
    end

    return value if value.each_char.one?

    nil
  rescue RangeError
    nil
  end

  def wu_zhao(text)
    translate_characters(text, zetian_map)
  rescue StandardError
    text.to_s
  end

  def singapore_1969(text)
    translate_characters(text, singapore_1969_map)
  rescue StandardError
    text.to_s
  end

  def singapore_1969_entries
    @singapore_1969_entries ||= begin
      path = Rails.root.join("config", "singapore_1969.tsv")
      entries = []

      File.foreach(path, mode: "r:bom|utf-8") do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        source, target = line.split(/\t/, 2)
        next if source.to_s.empty? || target.to_s.empty?

        entries << [source, target]
      end

      entries.freeze
    end
  rescue Errno::ENOENT, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
    [].freeze
  end

  def singapore_1969_map
    @singapore_1969_map ||= singapore_1969_entries.each_with_object({}) do |(source, target), map|
      # An IDS records an unencoded historical graph, but a normal font cannot
      # render the IDS as that graph. Preserve the source character on screen
      # until Unicode assigns a scalar value; keep the IDS in the data table.
      next unless source.each_char.one? && target.each_char.one?

      map[source] = target
    end.freeze
  end

  def shinjitai(text)
    # OpenCC's t2jp configuration normalises CJK Compatibility Ideographs
    # before applying the Shinjitai reverse dictionary. Restrict Unicode
    # normalisation to those two compatibility blocks so unrelated text is
    # left byte-for-byte equivalent apart from the requested Han conversion.
    source = normalise_cjk_compatibility_ideographs(text)
    translate_characters(source, shinjitai_map)
  rescue StandardError
    text.to_s
  end

  def zetian_map
    Rails.cache.fetch("character_standards:zetian:v2") do
      rows = VariantMapping.where(source: ZETIAN_SOURCE)
                           .order(:id)
                           .pluck(:base_codepoint, :variant_codepoint)

      grouped = rows.group_by(&:first)
      map = {}

      grouped.each do |base_codepoint, variants|
        base = codepoint_to_character(base_codepoint)
        next if base.nil?

        available = variants.filter_map { |_base, variant| codepoint_to_character(variant) }
        next if available.empty?

        preferred = ZETIAN_PREFERRED_VARIANTS[base]
        map[base] = preferred && available.include?(preferred) ? preferred : available.first
      end

      ZETIAN_BASE_ALIASES.each do |alias_character, stored_base|
        map[alias_character] = map[stored_base] if map.key?(stored_base)
      end

      map.freeze
    end
  rescue StandardError
    {}
  end

  def shinjitai_map
    @shinjitai_map ||= begin
      path = Rails.root.join("config", "shinjitai_opencc.txt")
      map = {}

      File.foreach(path, mode: "r:bom|utf-8") do |line|
        line = line.strip
        next if line.empty? || line.start_with?("#")

        shinjitai, old_forms = line.split(/\t/, 2)
        next if shinjitai.to_s.empty? || old_forms.to_s.empty?

        old_forms.split(/\s+/).each do |old_form|
          next if old_form == shinjitai
          map[old_form] ||= shinjitai
        end
      end

      SHINJITAI_REVERSE_PREFERENCES.each do |old_form, shinjitai|
        map[old_form] = shinjitai
      end

      map.freeze
    end
  rescue Errno::ENOENT, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
    {}
  end

  def translate_characters(text, map)
    value = text.to_s
    return value if value.empty? || map.empty?

    value.each_char.map { |character| map.fetch(character, character) }.join
  end

  def normalise_cjk_compatibility_ideographs(text)
    text.to_s.each_char.map do |character|
      codepoint = character.ord
      if (0xF900..0xFAFF).cover?(codepoint) || (0x2F800..0x2FA1F).cover?(codepoint)
        character.unicode_normalize(:nfc)
      else
        character
      end
    end.join
  end

  def codepoint_to_character(value)
    Integer(value).chr(Encoding::UTF_8)
  rescue ArgumentError, RangeError, TypeError
    nil
  end

  def normalise_mode(mode)
    mode.to_s.strip.downcase.tr(" ", "_").tr("-", "_").to_sym
  end
end
