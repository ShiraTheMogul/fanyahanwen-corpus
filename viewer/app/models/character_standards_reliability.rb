# frozen_string_literal: true

require "digest"

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
  # 《第二次汉字简化方案（草案）》has two distinct historical stages. Table
  # membership is therefore data, not something inferred from VariantMapping.
  #
  # Pipeline:
  #   erjian_1: any input -> Mainland Simplified -> 第一表
  #   erjian_2: any input -> Mainland Simplified -> 第一表 -> 第二表
  #
  # The executable TSVs contain only mappings whose intended output can be
  # represented by a defensible UCS scalar or sequence. BabelStone Erjian uses
  # ordinary code-point positions as font slots for many still-unencoded forms;
  # those slot characters must never leak into plain-text conversion.
  #
  # Each historical table is applied in a single pass. This matters because a
  # sequential chain of gsub! calls can accidentally treat the output of one
  # rule as the input of another rule from the same table.
  #
  # Singapore 1969 is independent and keeps its Traditional-base path.

  ERJIAN_TABLE_PATHS = {
    1 => "config/erjian_1977_table1.tsv",
    2 => "config/erjian_1977_table2.tsv"
  }.freeze

  ERJIAN_RESOURCE_PROBES = {
    1 => {
      "舞" => "午",
      "雪" => "𫜹",
      "蚯蚓" => "丘引"
    },
    2 => {
      "鞭" => "卞",
      "澳" => "沃",
      "捡" => "拣",
      "襟" => "𥘞",
      "襻" => "𥘽",
      "裤" => "䃿",
      "漏" => "屚",
      "蜗" => "呙",
      "娲" => "呙",
      "繐" => "𬜨",
      "𰬸" => "𬜨",
      "鹦鹉" => "𰋷武",
      "数" => "𮲓",
      "谏" => "𫍝",
      "缭" => "𱺑",
      "磅礴" => "㝑薄",
      "舢舨" => "舢板",
      "雕刻" => "刁刻"
    }
  }.freeze

  ERJIAN_EXPECTED_RULE_COUNTS = {
    1 => 278,
    2 => 266
  }.freeze

  # SHA-256 of the logical "source<TAB>target\n" rule stream. Comments, BOM,
  # and line-ending changes therefore cannot masquerade as a repertoire change.
  ERJIAN_RULE_DIGESTS = {
    1 => "b52944a6d094538cec3059bc0e782e62a4cb4c6c38acbda1b43b25c20d300b7a",
    2 => "b453112774180a00a874d831b4f3ac63b28c379d1d717bc239d7744a3b14b0f1"
  }.freeze

  # These historical sources still lack a defensible plain-text UCS output for
  # the intended final 二簡 glyph, or are context-sensitive in a way that cannot
  # be represented by a safe executable rule. They must not re-enter the table
  # as PUA values, BabelStone font-slot code points, intermediate component
  # forms, or guessed unifications.
  ERJIAN_REJECTED_STANDIN_KEYS = {
    1 => [].freeze,
    2 => %w[
      雕 嚼 赢 霸 瓣 避 簿 戳 诞 翻 繁 逢 缝
      耩 警 儆 厩 厥 痢 律 率 聊 螟 蘑 遣 谴 瞧 瓤 攘 孺 蠕 辱 褥
      膻 剩 霜 肆 艇 臀 膝 隙 辖 暇 霞 厦 遥 遗 毅 疑 鹰 庸 幽 舆 愚 隅
      遭 澡 绽 涨 胀 踵 赚 插 锸 臿 德 衮 滚 磙 侵 攀 然 弱 滕 藤 象
      搜 嗖 飕 第 嚏 涕 斓 韩
    ].freeze
  }.freeze

  def erjian_resource_path(round)
    relative = ERJIAN_TABLE_PATHS.fetch(Integer(round))
    Rails.root.join(relative)
  rescue ArgumentError, TypeError, KeyError
    nil
  end

  def erjian_resource_stamp(round)
    path = erjian_resource_path(round)
    return nil unless path&.file?

    [path.mtime.to_f, path.size].freeze
  end

  def erjian_resource_file_available?(round)
    path = erjian_resource_path(round)
    path&.file? && path.size.positive?
  rescue NameError
    false
  end

  # Read a stage-specific resource once and cache it by file stamp. Duplicate
  # sources are rejected instead of silently allowing a later row to overwrite
  # an earlier one.
  def erjian_round_rules(round)
    wanted = Integer(round)
    relative = ERJIAN_TABLE_PATHS.fetch(wanted)
    path = Rails.root.join(relative)
    raise CharacterStandards::ConversionUnavailable,
          "二簡 table #{wanted} resource is unavailable: #{relative}" unless path.file?

    stamp = [path.mtime.to_f, path.size].freeze
    @erjian_rule_cache ||= {}
    cached = @erjian_rule_cache[wanted]
    return cached.fetch(:rules) if cached && cached.fetch(:stamp) == stamp

    rules = []
    seen_sources = {}

    File.foreach(path, mode: "r:bom|utf-8").with_index(1) do |line, line_number|
      line = line.strip
      next if line.empty? || line.start_with?("#")

      source, target = line.split("\t", 2)
      source = source.to_s
      target = target.to_s
      next if source.empty? || target.empty?

      if seen_sources.key?(source)
        raise CharacterStandards::ConversionUnavailable,
              "二簡 table #{wanted} resource repeats source #{source.inspect} " \
              "on lines #{seen_sources.fetch(source)} and #{line_number}"
      end

      seen_sources[source] = line_number
      rules << [source.freeze, target.freeze].freeze
    end

    rules = rules.freeze
    validate_erjian_rules!(wanted, rules)

    @erjian_rule_cache[wanted] = { stamp: stamp, rules: rules }.freeze
    rules
  rescue CharacterStandards::ConversionUnavailable
    raise
  rescue Errno::ENOENT, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError,
         ArgumentError, TypeError, KeyError => error
    raise CharacterStandards::ConversionUnavailable,
          "二簡 table #{round} resource could not be loaded: #{error.message}"
  end

  def erjian_rules_digest(rules)
    payload = rules.map { |source, target| "#{source}\t#{target}\n" }.join
    Digest::SHA256.hexdigest(payload)
  end

  def validate_erjian_rules!(round, rules)
    wanted = Integer(round)
    expected_count = ERJIAN_EXPECTED_RULE_COUNTS.fetch(wanted)
    if rules.length != expected_count
      raise CharacterStandards::ConversionUnavailable,
            "二簡 table #{wanted} resource has #{rules.length} rules; expected exactly #{expected_count}"
    end

    expected_digest = ERJIAN_RULE_DIGESTS.fetch(wanted)
    actual_digest = erjian_rules_digest(rules)
    unless actual_digest == expected_digest
      raise CharacterStandards::ConversionUnavailable,
            "二簡 table #{wanted} resource digest mismatch " \
            "(#{actual_digest}; expected #{expected_digest})"
    end

    lookup = rules.to_h
    ERJIAN_RESOURCE_PROBES.fetch(wanted).each do |source, expected_target|
      next if lookup[source] == expected_target

      raise CharacterStandards::ConversionUnavailable,
            "二簡 table #{wanted} resource failed its #{source}→#{expected_target} integrity probe"
    end

    rejected = ERJIAN_REJECTED_STANDIN_KEYS.fetch(wanted).select { |source| lookup.key?(source) }
    unless rejected.empty?
      raise CharacterStandards::ConversionUnavailable,
            "二簡 table #{wanted} contains unresolved/non-UCS stand-ins: #{rejected.join(', ')}"
    end

    true
  end

  # Build a single-pass longest-match matcher. Longer sources are placed first
  # so whole-word rules win over character rules that start at the same place.
  # Original resource order breaks ties deterministically.
  def build_erjian_matcher(rules)
    indexed = rules.each_with_index
    ordered_sources = indexed
                      .sort_by { |(rule, index)| [-rule.fetch(0).length, index] }
                      .map { |(rule, _index)| rule.fetch(0) }

    lookup = rules.to_h.freeze
    pattern = Regexp.union(ordered_sources).freeze

    {
      lookup: lookup,
      pattern: pattern
    }.freeze
  end

  def apply_erjian_matcher(text, matcher)
    value = text.to_s
    return value if value.empty?

    lookup = matcher.fetch(:lookup)
    value.gsub(matcher.fetch(:pattern)) { |matched| lookup.fetch(matched) }
  end

  # 第二表 is historically applied after 第一表. Its TSV retains source forms
  # as documented in the source table, so compile-time normalisation converts
  # those sources to the text that actually reaches the second pass. Example:
  # 叮咛 is already 丁咛 after 第一表, but still needs 第二表's 丁宁 result.
  def normalise_erjian_second_round_sources(rules)
    first_matcher = erjian_compiled_matcher(1)
    normalized = {}
    provenance = {}

    rules.each do |source, target|
      matcher_source = apply_erjian_matcher(source, first_matcher)

      if normalized.key?(matcher_source)
        existing = normalized.fetch(matcher_source)
        next if existing == target

        raise CharacterStandards::ConversionUnavailable,
              "二簡 table 2 source collision after 第一表: " \
              "#{provenance.fetch(matcher_source).inspect} and #{source.inspect} " \
              "both become #{matcher_source.inspect} with different targets"
      end

      normalized[matcher_source] = target
      provenance[matcher_source] = source
    end

    normalized.map { |source, target| [source.freeze, target.freeze].freeze }.freeze
  end

  def erjian_compiled_matcher(round)
    wanted = Integer(round)
    stamps = wanted == 2 ? [erjian_resource_stamp(1), erjian_resource_stamp(2)] : [erjian_resource_stamp(1)]
    if stamps.any?(&:nil?)
      raise CharacterStandards::ConversionUnavailable,
            "二簡 table #{wanted} resource is unavailable"
    end

    @erjian_compiled_matcher_cache ||= {}
    cached = @erjian_compiled_matcher_cache[wanted]
    return cached.fetch(:matcher) if cached && cached.fetch(:stamps) == stamps

    rules = erjian_round_rules(wanted)
    effective_rules = wanted == 2 ? normalise_erjian_second_round_sources(rules) : rules
    matcher = build_erjian_matcher(effective_rules)

    @erjian_compiled_matcher_cache[wanted] = {
      stamps: stamps.freeze,
      matcher: matcher
    }.freeze

    matcher
  rescue CharacterStandards::ConversionUnavailable
    raise
  rescue ArgumentError, TypeError, KeyError => error
    raise CharacterStandards::ConversionUnavailable,
          "二簡 table #{round} matcher could not be compiled: #{error.message}"
  end

  def erjian_first_round_from_any(text)
    mainland = simplified(text)
    apply_erjian_matcher(mainland, erjian_compiled_matcher(1))
  rescue CharacterStandards::ConversionUnavailable
    raise
  end

  def erjian_second_round_from_any(text)
    first_round = erjian_first_round_from_any(text)
    apply_erjian_matcher(first_round, erjian_compiled_matcher(2))
  rescue CharacterStandards::ConversionUnavailable
    raise
  end

  # Compatibility for older callers. The shared converter name denotes the
  # first cumulative state; convert(..., :erjian_2) explicitly adds 第二表.
  def erjian_from_any(text)
    erjian_first_round_from_any(text)
  end
end
