# frozen_string_literal: true

require "digest"

# WFG-backed Kangxi character standards.
#
# This module is prepended to CharacterStandards' singleton class by the
# initializer. It adds modes without mutating CharacterStandards::PROFILES,
# which is frozen on current main. Existing conversion dispatch therefore
# remains owned by CharacterStandardsReliability.
module CharacterStandardsKangxi
  MODES = %i[kangxi_standard kangxi_ancient].freeze

  RESOURCE_PATHS = {
    kangxi_standard: "config/kangxi_standard.tsv",
    kangxi_ancient: "config/kangxi_ancient.tsv"
  }.freeze

  RESOURCE_RULE_COUNTS = {
    kangxi_standard: 6_363,
    kangxi_ancient: 1_294
  }.freeze

  RESOURCE_SHA256 = {
    kangxi_standard: "7ba08c377eaeab90fabffad232d4851f480902dfd2ddadfe31c3539976697fe2",
    kangxi_ancient: "d3e1e25370d769283c794bcd60a0ba45f6dbd1da02249cfbe36337186ba260c4"
  }.freeze

  def allowed_modes
    (super + MODES).uniq.freeze
  end

  def selectable_modes
    (super + MODES.select { |mode| available?(mode) }).uniq.freeze
  end

  def available?(mode)
    normalized = kangxi_normalise_mode(mode)
    return kangxi_resource_valid?(normalized) if MODES.include?(normalized)

    super
  end

  def convert(text, mode)
    value = text.to_s
    return value if value.empty?

    case kangxi_normalise_mode(mode)
    when :kangxi_standard
      kangxi_standard_from_any(value)
    when :kangxi_ancient
      kangxi_ancient_from_any(value)
    else
      super
    end
  end

  # User-facing conversion is deliberately simple: normalize to OpenCC
  # Standard Traditional, then apply the reviewed WFG-derived Kangxi map.
  def kangxi_standard_from_any(text)
    source = traditional(text.to_s)
    kangxi_translate(source, kangxi_map(:kangxi_standard))
  end

  # 古文 is a preference layer over the ordinary Kangxi standard. The table
  # chooses the first portable Unicode 古文 listed by WFG in source order.
  def kangxi_ancient_from_any(text)
    source = kangxi_standard_from_any(text.to_s)
    kangxi_translate(source, kangxi_map(:kangxi_ancient))
  end

  def kangxi_map(mode)
    normalized = kangxi_normalise_mode(mode)
    raise CharacterStandards::ConversionUnavailable, "Unknown Kangxi standard #{mode.inspect}" unless MODES.include?(normalized)
    path = Rails.root.join(RESOURCE_PATHS.fetch(normalized))
    raise CharacterStandards::ConversionUnavailable, "Kangxi standard resource is unavailable" unless kangxi_resource_bytes_valid?(normalized, path)
    stamp = [path.mtime.to_f, path.size].freeze
    @kangxi_map_cache ||= {}
    cached = @kangxi_map_cache[normalized]
    return cached.fetch(:map) if cached && cached.fetch(:stamp) == stamp

    map = {}
    File.foreach(path, mode: "r:bom|utf-8").with_index(1) do |line, line_number|
      line = line.delete_suffix("\n").delete_suffix("\r")
      next if line.empty? || line.start_with?("#")

      source, target = line.split("\t", 2)
      unless source&.each_char&.one? && target&.each_char&.one?
        raise CharacterStandards::ConversionUnavailable,
              "Kangxi resource #{normalized} has a non-character rule on line #{line_number}"
      end
      if map.key?(source)
        raise CharacterStandards::ConversionUnavailable,
              "Kangxi resource #{normalized} repeats source #{source.inspect}"
      end

      map[source.freeze] = target.freeze
    end

    expected = RESOURCE_RULE_COUNTS.fetch(normalized)
    if map.length != expected
      raise CharacterStandards::ConversionUnavailable,
            "Kangxi resource #{normalized} has #{map.length} rules; expected #{expected}"
    end

    frozen = map.freeze
    @kangxi_map_cache[normalized] = { stamp: stamp, map: frozen }.freeze
    frozen
  rescue Errno::ENOENT, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError => error
    raise CharacterStandards::ConversionUnavailable,
          "Kangxi resource #{normalized} could not be loaded: #{error.message}"
  end

  def kangxi_resource_valid?(mode)
    normalized = kangxi_normalise_mode(mode)
    path_string = RESOURCE_PATHS[normalized]
    return false unless path_string

    path = Rails.root.join(path_string)
    return false unless path.file? && path.size.positive?

    stamp = [path.mtime.to_f, path.size].freeze
    @kangxi_resource_validation_cache ||= {}
    cached = @kangxi_resource_validation_cache[normalized]
    return cached.fetch(:valid) if cached && cached.fetch(:stamp) == stamp

    valid = kangxi_resource_bytes_valid?(normalized, path)

    if valid
      # Parsing verifies the exact rule count and catches duplicate/malformed rows.
      @kangxi_resource_validation_cache.delete(normalized)
      begin
        kangxi_map(normalized)
      rescue CharacterStandards::ConversionUnavailable
        valid = false
      end
    end

    @kangxi_resource_validation_cache[normalized] = { stamp: stamp, valid: valid }.freeze
    valid
  rescue Errno::ENOENT, KeyError
    false
  end


  def kangxi_resource_bytes_valid?(normalized, path)
    bytes = File.binread(path)
    bytes.start_with?("\xEF\xBB\xBF".b) &&
      Digest::SHA256.hexdigest(bytes) == RESOURCE_SHA256.fetch(normalized)
  rescue Errno::ENOENT, KeyError
    false
  end

  private

  def kangxi_normalise_mode(mode)
    mode.to_s.strip.downcase.tr(" ", "_").to_sym
  end

  def kangxi_translate(text, map)
    text.to_s.each_char.map { |character| map.fetch(character, character) }.join
  end
end
