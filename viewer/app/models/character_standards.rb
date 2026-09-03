# frozen_string_literal: true

require "digest"
require "json"

# Display-only Han character-standard conversions.
#
# Corpus files and database values are never changed. Views ask this object for
# a transformed copy. Each selectable mode has one explicit implementation so
# adding a new standard does not require another case statement in a helper.
module CharacterStandards
  PROFILES = {
    original:              { converter: :identity },
    traditional:           { converter: :traditional },
    simplified:            { converter: :simplified },
    mainland_traditional:  { converter: :mainland_traditional, resource: :mainland_traditional },
    taiwan_traditional:    { converter: :taiwan_traditional },
    hong_kong_traditional: { converter: :hong_kong_traditional },
    macau_traditional:     { converter: :macau_traditional },
    singapore_modern:      { converter: :singapore_modern },
    malaysia_simplified:   { converter: :malaysia_simplified },
    singapore_1969:        { converter: :singapore_1969_from_any },
    wu_zhao:               { converter: :wu_zhao },
    shinjitai:             { converter: :shinjitai_from_any },
    erjian_1:              { converter: :erjian_from_any },
    erjian_2:              { converter: :erjian_from_any }
  }.freeze

  MODES = PROFILES.keys.freeze
  ERJIAN_MODES = %i[erjian_1 erjian_2].freeze
  ZETIAN_SOURCE = "Zetian Script (則天文字)"

  MAINLAND_TRADITIONAL_PATH = "config/mainland_traditional_characters.txt"
  MAINLAND_TRADITIONAL_PHRASES_PATH = "config/mainland_traditional_phrases.txt"
  MAINLAND_TRADITIONAL_COMPATIBILITY_PATH = "config/mainland_traditional_cjk_compatibility.txt"
  MAINLAND_TRADITIONAL_CONFIG_PATH = "config/mainland_traditional_opencc.json"
  MAINLAND_TRADITIONAL_LICENSE_PATH = "config/mainland_traditional_OPENCC_LICENSE.txt"
  MAINLAND_TRADITIONAL_MANIFEST_PATH = "config/mainland_traditional_manifest.json"
  MAINLAND_TRADITIONAL_UPSTREAM_COMMIT = "33ba491670d5aff20bfbc41d5f412ac8607ba722"

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

  # The UI uses this to hide a standard whose external resource has not yet
  # been installed. Session validation still accepts all known modes so an old
  # session cannot crash when resources are temporarily absent.
  def selectable_modes
    MODES.select { |mode| available?(mode) }
  end

  def available?(mode)
    profile = PROFILES[normalise_mode(mode)]
    return false unless profile

    case profile[:resource]
    when :mainland_traditional
      mainland_traditional_resource_valid?
    else
      true
    end
  end

  def erjian_mode?(mode)
    ERJIAN_MODES.include?(normalise_mode(mode))
  end

  # External conversion data is enabled only when the fetch script's manifest
  # matches every installed byte. This prevents a partial or edited dictionary
  # from silently presenting itself as the named standard.
  def mainland_traditional_resource_valid?
    paths = {
      "data_file" => Rails.root.join(MAINLAND_TRADITIONAL_PATH),
      "phrases_file" => Rails.root.join(MAINLAND_TRADITIONAL_PHRASES_PATH),
      "compatibility_file" => Rails.root.join(MAINLAND_TRADITIONAL_COMPATIBILITY_PATH),
      "config_file" => Rails.root.join(MAINLAND_TRADITIONAL_CONFIG_PATH),
      "license_file" => Rails.root.join(MAINLAND_TRADITIONAL_LICENSE_PATH)
    }
    manifest_path = Rails.root.join(MAINLAND_TRADITIONAL_MANIFEST_PATH)
    return false unless manifest_path.file? && paths.values.all?(&:file?)

    stamp = paths.values.flat_map { |path| [path.mtime.to_f, path.size] } +
            [manifest_path.mtime.to_f, manifest_path.size]
    if @mainland_resource_validation_stamp == stamp
      return @mainland_resource_validation_result == true
    end

    manifest_text = File.open(manifest_path, "r:bom|utf-8", &:read)
    manifest = JSON.parse(manifest_text)

    valid = manifest.fetch("upstream_commit") == MAINLAND_TRADITIONAL_UPSTREAM_COMMIT
    paths.each do |manifest_key, path|
      bytes = File.binread(path)
      valid &&= manifest.fetch(manifest_key) == path.basename.to_s
      valid &&= manifest.fetch("#{manifest_key.delete_suffix('_file')}_sha256") == Digest::SHA256.hexdigest(bytes)

      # The three upstream dictionaries contain Han script and must retain the
      # repository's UTF-8-with-BOM invariant after installation.
      if %w[data_file phrases_file compatibility_file].include?(manifest_key)
        valid &&= bytes.start_with?("\xEF\xBB\xBF".b)
      end
    end

    @mainland_resource_validation_stamp = stamp
    @mainland_resource_validation_result = valid
    valid
  rescue JSON::ParserError, KeyError, Errno::ENOENT, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
    @mainland_resource_validation_result = false
    false
  end

  def convert(text, mode)
    value = text.to_s
    return value if value.empty?

    profile = PROFILES[normalise_mode(mode)] || PROFILES.fetch(:original)
    return value unless available?(mode)

    public_send(profile.fetch(:converter), value)
  rescue StandardError
    value
  end

  def identity(text)
    text.to_s
  end

  # OpenCC Standard Traditional remains useful as a neutral intermediate form.
  def traditional(text)
    opencc_script_convert(text, :s2t, :traditional)
  end

  def simplified(text)
    opencc_script_convert(text, :t2s, :simplified)
  end

  # Regional profiles deliberately use OpenCC's character/orthographic
  # regionalisation configs, not the modern terminology phrase profiles such
  # as s2twp. Corpus wording therefore is not localised into modern vocabulary.
  def taiwan_traditional(text)
    source = traditional(text)
    opencc_convert(source, :t2tw) || source
  end

  def hong_kong_traditional(text)
    source = traditional(text)
    opencc_convert(source, :t2hk) || source
  end

  # MediaWiki and zhconv currently use the Hong Kong base mapping for Macau.
  # Keeping a distinct profile key lets a Macau-specific map be added later
  # without changing stored user preferences.
  def macau_traditional(text)
    hong_kong_traditional(text)
  end

  # Contemporary Singapore and Malaysia use the same automatic simplified base
  # mapping as Mainland Chinese in MediaWiki/zhconv. Their profile keys remain
  # separate so future regional additions do not require a preference migration.
  def singapore_modern(text)
    simplified(text)
  end

  def malaysia_simplified(text)
    simplified(text)
  end

  # Mainland Traditional is a two-stage conversion:
  # 1. OpenCC resolves Simplified/Traditional lexical ambiguity into its
  #    Standard Traditional intermediate form.
  # 2. TerryTian-tech, Yi Jianpeng, Hu Xinmei and Duan Yatong's t2gov data
  #    applies the PRC standard's phrase-aware and character-level choices.
  #
  # This is the upstream t2gov architecture with local, hash-verified filenames.
  # TGPhrases here performs orthographic/semantic disambiguation (for example,
  # context-sensitive merged forms); it is separate from OpenCC's modern
  # regional terminology profiles such as s2twp, which Fanya does not apply.
  def mainland_traditional(text)
    source = traditional(text)
    converted = opencc_convert_file(source, Rails.root.join(MAINLAND_TRADITIONAL_CONFIG_PATH))
    converted.nil? ? text.to_s : converted
  rescue StandardError
    text.to_s
  end

  def opencc_script_convert(text, config, fallback_mode)
    value = text.to_s
    return value if value.empty?

    converted = opencc_convert(value, config)
    return converted unless converted.nil?

    unihan_script_convert(value, fallback_mode)
  end

  def opencc_convert(text, config)
    require "opencc" unless defined?(::OpenCC)

    if ::OpenCC.respond_to?(config)
      return ::OpenCC.public_send(config, text.to_s)
    end

    converter = ::OpenCC::Converter.new(config.to_s)
    begin
      converter.convert(text.to_s)
    ensure
      converter.close if converter
    end
  rescue LoadError, StandardError
    nil
  rescue Exception => error # opencc-rb 1.0.6 raises Exception when opencc_open fails.
    raise if error.is_a?(SystemExit) || error.is_a?(Interrupt) || error.is_a?(SignalException)
    nil
  end

  def opencc_convert_file(text, config_path)
    require "opencc" unless defined?(::OpenCC)

    converter = ::OpenCC::Converter.new(config_path.to_s)
    begin
      converter.convert(text.to_s)
    ensure
      converter.close if converter
    end
  rescue LoadError, StandardError
    nil
  rescue Exception => error # opencc-rb 1.0.6 raises Exception when opencc_open fails.
    raise if error.is_a?(SystemExit) || error.is_a?(Interrupt) || error.is_a?(SignalException)
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

  def singapore_1969_from_any(text)
    singapore_1969(traditional(text))
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

  def shinjitai_from_any(text)
    shinjitai(traditional(text))
  end

  def shinjitai(text)
    source = normalise_cjk_compatibility_ideographs(text)
    translate_characters(source, shinjitai_map)
  rescue StandardError
    text.to_s
  end

  def erjian_from_any(text)
    simplified(text)
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
