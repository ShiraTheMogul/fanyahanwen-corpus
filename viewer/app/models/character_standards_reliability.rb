# frozen_string_literal: true

# Reliability for named character-standard conversions.
#
# Named standards must either complete their OpenCC stage or report that the
# converter is unavailable. 
module CharacterStandardsReliability
  def convert(text, mode)
    value = text.to_s
    return value if value.empty?

    normalized = normalise_mode(mode)
    profile = CharacterStandards::PROFILES[normalized] || CharacterStandards::PROFILES.fetch(:original)
    return value unless available?(mode)

    # 二簡 has two cumulative historical stages. The first-round profile is
    # Mainland Simplified plus the first-round overlay. The second-round profile
    # must pass through that complete first-round state before its own overlay.
    # Keeping this dispatch here also avoids the old PROFILES table's accidental
    # use of the same one-stage converter for both selections.
    case normalized
    when :erjian_1
      erjian_first_round_from_any(value)
    when :erjian_2
      erjian_second_round_from_any(value)
    else
      public_send(profile.fetch(:converter), value)
    end
  rescue CharacterStandards::ConversionUnavailable
    raise
  rescue StandardError => error
    Rails.logger.error("[character_standards] #{mode.inspect} conversion failed: #{error.class}: #{error.message}") if defined?(Rails)
    value
  end

  OPENCC_FOUNDATION_PROBES = {
    "s2t" => ["区动战这乱", "區動戰這亂"],
    "t2s" => ["區動戰這亂", "区动战这乱"]
  }.freeze

  # OpenCC's C API names configuration *files* (s2t.json, t2s.json, ...).
  # opencc-rb 1.0.6 is older and its convenience methods pass bare names such
  # as "t2s". Newer OpenCC installations are not obliged to resolve those
  # aliases. Prefer a real JSON path/name, then retain the bare name as a
  # compatibility candidate for older installations.
  def opencc_config_candidates(config)
    raw = config.to_s
    return [raw] if raw.empty? || raw.end_with?(".json") || raw.include?(File::SEPARATOR) || raw.include?("/")

    filename = "#{raw}.json"
    library_dirs = [ENV["LD_LIBRARY_PATH"], ENV["LIBRARY_PATH"]]
                   .compact
                   .flat_map { |value| value.to_s.split(File::PATH_SEPARATOR) }
                   .reject(&:empty?)
    derived_data_dirs = library_dirs.flat_map do |directory|
      [
        File.expand_path("../share/opencc", directory),
        File.expand_path("../../share/opencc", directory)
      ]
    end

    directories = [
      ENV["OPENCC_DATA_DIR"],
      "/usr/share/opencc",
      "/usr/local/share/opencc",
      *derived_data_dirs
    ].compact.map(&:to_s).reject(&:empty?).uniq

    absolute = directories.filter_map do |directory|
      path = File.join(directory, filename)
      path if File.file?(path)
    end

    (absolute + [filename, raw]).uniq
  end

  def close_opencc_converter(converter)
    converter&.close
  rescue StandardError
    nil
  rescue Exception => error
    raise if error.is_a?(SystemExit) || error.is_a?(Interrupt) || error.is_a?(SignalException)
    nil
  end

  def verify_opencc_foundation!(converter, config_name)
    probe = OPENCC_FOUNDATION_PROBES[config_name.to_s.sub(/\.json\z/, "")]
    return true unless probe

    input, expected = probe
    actual = converter.convert(input)
    return true if actual == expected

    raise CharacterStandards::ConversionUnavailable,
          "OpenCC opened #{config_name.inspect} but failed its #{input} → #{expected} health check (got #{actual.inspect})."
  end

  # Use the documented OpenCC configuration filename first. This also lets an
  # explicitly configured OPENCC_DATA_DIR work when libopencc itself lives in a
  # user-local prefix. A successful foundation converter is smoke-tested before
  # it is allowed to touch user text, so an identity/no-op converter can never
  # produce a misleading HTTP 200 response.
  def opencc_convert(text, config)
    require "opencc" unless defined?(::OpenCC)

    errors = []
    opencc_config_candidates(config).each do |candidate|
      converter = nil
      begin
        converter = ::OpenCC::Converter.new(candidate)
        verify_opencc_foundation!(converter, config.to_s)
        converted = converter.convert(text.to_s)
        return converted unless converted.nil?
        errors << "#{candidate}: conversion returned nil"
      rescue CharacterStandards::ConversionUnavailable => error
        errors << "#{candidate}: #{error.message}"
      rescue LoadError, StandardError => error
        errors << "#{candidate}: #{error.class}: #{error.message}"
      rescue Exception => error # opencc-rb raises Exception when opencc_open fails.
        raise if error.is_a?(SystemExit) || error.is_a?(Interrupt) || error.is_a?(SignalException)
        errors << "#{candidate}: #{error.class}: #{error.message}"
      ensure
        close_opencc_converter(converter)
      end
    end

    Rails.logger.error("[character_standards] OpenCC #{config} candidates failed: #{errors.join(' | ')}") if defined?(Rails)
    nil
  end

  # Standard Traditional/Simplified is the foundation for several named
  # standards. If OpenCC cannot perform that stage, do not silently substitute
  # the much smaller Unihan variant map: that is how mixed strings such as
  # 區动戰这亂 can be produced. Regional second-stage converters still retain
  # their existing `... || source` fallback, so a missing t2hk/t2tw resource can
  # safely keep an already-complete Standard Traditional intermediate.
  def opencc_script_convert(text, config, _fallback_mode)
    value = text.to_s
    return value if value.empty?

    converted = opencc_convert(value, config)
    return converted unless converted.nil?

    raise CharacterStandards::ConversionUnavailable,
          "OpenCC could not run the #{config} conversion. Check the OpenCC runtime/config data (Debian/Ubuntu: libopencc-data)."
  end

  def opencc_convert_file(text, config_path)
    require "opencc" unless defined?(::OpenCC)

    converter = nil
    begin
      converter = ::OpenCC::Converter.new(config_path.to_s)
      converted = converter.convert(text.to_s)
      return converted unless converted.nil?
    rescue LoadError, StandardError => error
      Rails.logger.error("[character_standards] OpenCC file conversion failed: #{error.class}: #{error.message}") if defined?(Rails)
    rescue Exception => error # opencc-rb raises Exception when opencc_open fails.
      raise if error.is_a?(SystemExit) || error.is_a?(Interrupt) || error.is_a?(SignalException)
      Rails.logger.error("[character_standards] OpenCC file conversion failed: #{error.class}: #{error.message}") if defined?(Rails)
    ensure
      close_opencc_converter(converter)
    end

    raise CharacterStandards::ConversionUnavailable,
          "OpenCC could not run the conversion config #{config_path}."
  end

  # If Standard Traditional succeeded and only the PRC-specific t2gov pass
  # fails, retain the successful Traditional intermediate. A failure in the
  # first stage still propagates to the caller.
  def mainland_traditional(text)
    source = traditional(text)
    begin
      opencc_convert_file(source, Rails.root.join(CharacterStandards::MAINLAND_TRADITIONAL_CONFIG_PATH))
    rescue CharacterStandards::ConversionUnavailable => error
      Rails.logger.error("[character_standards] Mainland Traditional regionalisation failed: #{error.message}") if defined?(Rails)
      source
    end
  end

  # 則天文字 is applied to a Standard Traditional base. Characters with no
  # special 則天 form therefore remain normal Traditional characters.
  def wu_zhao(text)
    source = traditional(text)
    translate_characters(source, zetian_map)
  rescue CharacterStandards::ConversionUnavailable
    raise
  rescue StandardError => error
    Rails.logger.error("[character_standards] Wu Zhao conversion failed: #{error.class}: #{error.message}") if defined?(Rails)
    source || text.to_s
  end
  # ---- 二簡 cumulative pipeline ------------------------------------------------
  #
  # 《第二次汉字简化方案（草案）》has two distinct tables.  Their table
  # membership is part of the standard itself; it must not be guessed from the
  # free-text `VariantMapping.source` column at request time.
  #
  # Pipeline:
  #   erjian_1: any input -> Mainland Simplified -> 第一表
  #   erjian_2: any input -> Mainland Simplified -> 第一表 -> 第二表
  #
  # Singapore 1969 is deliberately independent and continues to use its own
  # Traditional-base conversion in CharacterStandards#singapore_1969_from_any.

  ERJIAN_TABLE_PATHS = {
    1 => "config/erjian_1977_table1.tsv",
    2 => "config/erjian_1977_table2.tsv"
  }.freeze

  ERJIAN_RESOURCE_PROBES = {
    1 => {
      "舞" => "午",
      "道" => "辺",
      "蚯蚓" => "丘引"
    },
    2 => {
      "鞭" => "卞",
      "澳" => "沃",
      "鹦鹉" => "𰋷武"
    }
  }.freeze

  ERJIAN_MINIMUM_RULE_COUNTS = {
    1 => 250,
    2 => 250
  }.freeze

  def erjian_resource_file_available?(round)
    relative = ERJIAN_TABLE_PATHS[Integer(round)]
    return false if relative.nil?

    path = Rails.root.join(relative)
    path.file? && path.size.positive?
  rescue ArgumentError, TypeError, NameError
    false
  end

  # Read the reviewed, stage-specific resource once and cache it by file stamp.
  # This intentionally does not touch VariantMapping.  A database-wide DISTINCT
  # source scan on every Writer keystroke was both expensive and semantically
  # incapable of distinguishing 第一表 from 第二表 when the rows shared the
  # historical source title.
  def erjian_round_rules(round)
    wanted = Integer(round)
    relative = ERJIAN_TABLE_PATHS.fetch(wanted)
    path = Rails.root.join(relative)
    raise CharacterStandards::ConversionUnavailable,
          "二簡 table #{wanted} resource is unavailable: #{relative}" unless path.file?

    stamp = [path.mtime.to_f, path.size]
    @erjian_rule_cache ||= {}
    cached = @erjian_rule_cache[wanted]
    return cached.fetch(:rules) if cached && cached.fetch(:stamp) == stamp

    ordered = {}
    File.foreach(path, mode: "r:bom|utf-8") do |line|
      line = line.strip
      next if line.empty? || line.start_with?("#")

      source, target = line.split("\t", 2)
      source = source.to_s
      target = target.to_s
      next if source.empty? || target.empty?

      # Ruby Hash preserves insertion position when an existing key is updated,
      # matching a JavaScript object's Object.entries order while allowing a
      # later reviewed value for the same source key.
      ordered[source] = target
    end

    rules = ordered.to_a.freeze
    validate_erjian_rules!(wanted, rules)

    @erjian_rule_cache[wanted] = { stamp: stamp.freeze, rules: rules }.freeze
    rules
  rescue CharacterStandards::ConversionUnavailable
    raise
  rescue Errno::ENOENT, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError,
         ArgumentError, TypeError, KeyError => error
    raise CharacterStandards::ConversionUnavailable,
          "二簡 table #{round} resource could not be loaded: #{error.message}"
  end

  def validate_erjian_rules!(round, rules)
    wanted = Integer(round)
    minimum = ERJIAN_MINIMUM_RULE_COUNTS.fetch(wanted)
    if rules.length < minimum
      raise CharacterStandards::ConversionUnavailable,
            "二簡 table #{wanted} resource is incomplete (#{rules.length} rules; expected at least #{minimum})"
    end

    lookup = rules.to_h
    ERJIAN_RESOURCE_PROBES.fetch(wanted).each do |source, expected|
      next if lookup[source] == expected

      raise CharacterStandards::ConversionUnavailable,
            "二簡 table #{wanted} resource failed its #{source}→#{expected} integrity probe"
    end
    true
  end

  # Apply rules in reviewed source order.  Some entries are whole-word
  # substitutions (for example 蚯蚓→丘引 and 鹦鹉→𰋷武), so a character-only
  # translation table is insufficient.
  def apply_erjian_rules(text, rules)
    value = text.to_s.dup
    rules.each do |source, target|
      value.gsub!(source, target)
    end
    value
  end

  def erjian_first_round_from_any(text)
    mainland = simplified(text)
    apply_erjian_rules(mainland, erjian_round_rules(1))
  rescue CharacterStandards::ConversionUnavailable
    raise
  end

  def erjian_second_round_from_any(text)
    first_round = erjian_first_round_from_any(text)
    apply_erjian_rules(first_round, erjian_round_rules(2))
  rescue CharacterStandards::ConversionUnavailable
    raise
  end

  # Compatibility for older callers.  The shared converter name now denotes
  # the first cumulative state only; convert(..., :erjian_2) explicitly adds
  # 第二表 after it.
  def erjian_from_any(text)
    erjian_first_round_from_any(text)
  end

end
