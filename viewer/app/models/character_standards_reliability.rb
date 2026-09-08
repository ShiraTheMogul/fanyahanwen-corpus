# frozen_string_literal: true

# Reliability for named character-standard conversions.
#
# Named standards must either complete their OpenCC stage or report that the
# converter is unavailable. 
module CharacterStandardsReliability
  def convert(text, mode)
    value = text.to_s
    return value if value.empty?

    profile = CharacterStandards::PROFILES[normalise_mode(mode)] || CharacterStandards::PROFILES.fetch(:original)
    return value unless available?(mode)

    public_send(profile.fetch(:converter), value)
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
end
