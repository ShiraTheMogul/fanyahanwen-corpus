# frozen_string_literal: true

require "date"

# One public gateway for deterministic calendar work used by the viewer,
# metadata dating, corpus-maintenance scripts, and future annotation code.
#
# Historical reign-era/ruler authority resolution remains in
# HistoricalDateResolver for now. It delegates deterministic calendar labels
# here, while this service deliberately does not duplicate authority databases.
class CalendarEngine
  NUMERAL_PATTERN = "元〇零○一二三四五六七八九十百千萬万兩两廿卅卌0123456789"
  NUMBER_CAPTURE = "[#{Regexp.escape(NUMERAL_PATTERN)}]+"

  STEMS = %w[甲 乙 丙 丁 戊 己 庚 辛 壬 癸].freeze
  BRANCHES = %w[子 丑 寅 卯 辰 巳 午 未 申 酉 戌 亥].freeze
  SEXAGENARY_NAMES = Array.new(60) { |index| "#{STEMS[index % 10]}#{BRANCHES[index % 12]}" }.freeze

  ERYA_YEAR_STEMS = {
    "甲" => "閼逢", "乙" => "旃蒙", "丙" => "柔兆", "丁" => "強圉", "戊" => "著雍",
    "己" => "屠維", "庚" => "上章", "辛" => "重光", "壬" => "玄黓", "癸" => "昭陽"
  }.freeze
  ERYA_YEAR_BRANCHES = {
    "寅" => "攝提格", "卯" => "單閼", "辰" => "執徐", "巳" => "大荒落",
    "午" => "敦牂", "未" => "協洽", "申" => "涒灘", "酉" => "作噩",
    "戌" => "閹茂", "亥" => "大淵獻", "子" => "困敦", "丑" => "赤奮若"
  }.freeze
  ERYA_MONTH_STEMS = {
    "甲" => "畢", "乙" => "橘", "丙" => "修", "丁" => "圉", "戊" => "厲",
    "己" => "則", "庚" => "窒", "辛" => "塞", "壬" => "終", "癸" => "極"
  }.freeze
  ERYA_MONTH_NAMES = {
    1 => "陬", 2 => "如", 3 => "寎", 4 => "余", 5 => "皋", 6 => "且",
    7 => "相", 8 => "壯", 9 => "玄", 10 => "陽", 11 => "辜", 12 => "涂"
  }.freeze
  ERYA_MONTH_VARIANTS = { "塗" => 12 }.freeze

  ERYA_SOURCE = {
    "label" => "《爾雅·釋天》",
    "citation" => "《爾雅·釋天》. In Sturgeon, Donald (Ed.), Chinese Text Project. (n.d.). Retrieved August 28, 2026.",
    "digital_editor" => "Sturgeon, Donald",
    "digital_repository" => "Chinese Text Project",
    "url" => "https://ctext.org/er-ya/shi-tian/zh"
  }.freeze
  SHANG_CYCLE_SOURCE = {
    "label" => "《甲骨文合集》37986",
    "note" => "Complete sixty-term stem-branch cycle attested on an oracle-bone table.",
    "citation" => "Takashima, Ken’ichi. (2015). A Little Primer of Chinese Oracle-Bone Inscriptions with Some Exercises. Harrassowitz, pp. 2–4.",
    "digital_repository" => "Wikimedia Commons",
    "url" => "https://commons.wikimedia.org/wiki/File:Heji_37986_Ganzhi_table.jpg"
  }.freeze

  # Signed absolute years use ordinary historical numbering: -1 = 1 BCE,
  # +1 = 1 CE, and zero is invalid. epoch_year is the absolute year carrying
  # epoch_number. "status" is exposed to callers so a configured convention is
  # never silently presented as a uniquely historical fact.
  YEAR_SYSTEMS = [
    {
      "key" => "minguo", "label" => "民國", "aliases" => %w[中華民國 中华民国 民國 民国 Minguo],
      "epoch_year" => 1912, "epoch_number" => 1, "country" => "China",
      "status" => "established", "convention" => "1912 CE = 民國元年",
      "calendar_frame" => "gregorian"
    },
    {
      "key" => "juche", "label" => "主體 / 주체", "aliases" => %w[主體 主体 주체 Juche],
      "epoch_year" => 1912, "epoch_number" => 1, "country" => "Korea",
      "status" => "established", "convention" => "1912 CE = year 1; no artificial upper bound",
      "calendar_frame" => "gregorian"
    },
    {
      "key" => "buddhist_era_common", "label" => "佛曆 / Buddhist Era",
      "aliases" => ["佛曆", "佛历", "Buddhist Era", "B.E.", "BE"],
      "epoch_year" => -543, "epoch_number" => 1, "country" => nil,
      "status" => "modern_convention",
      "convention" => "Common modern Buddhist Era convention; 1 BE = 543 BCE and 544 BE = 1 CE",
      "calendar_frame" => "gregorian"
    },
    {
      "key" => "huangdi_2697", "label" => "黃帝紀年（2697 BCE convention）",
      "aliases" => ["黃帝紀年（2697 BCE）", "黃帝紀年(2697 BCE)", "黄帝纪年（2697 BCE）", "黄帝纪年(2697 BCE)", "黃帝紀年", "黄帝纪年"],
      "epoch_year" => -2697, "epoch_number" => 1, "country" => "China",
      "status" => "variant_convention", "convention" => "2697 BCE = year 1",
      "calendar_frame" => nil
    },
    {
      "key" => "huangdi_2698", "label" => "黃帝紀年（2698 BCE convention）",
      "aliases" => ["黃帝紀年（2698 BCE）", "黃帝紀年(2698 BCE)", "黄帝纪年（2698 BCE）", "黄帝纪年(2698 BCE)", "黃帝紀年", "黄帝纪年"],
      "epoch_year" => -2698, "epoch_number" => 1, "country" => "China",
      "status" => "variant_convention", "convention" => "2698 BCE = year 1",
      "calendar_frame" => nil
    },
    {
      "key" => "tangyao", "label" => "唐堯紀年", "aliases" => ["唐堯紀年", "唐尧纪年"],
      "epoch_year" => -2156, "epoch_number" => 1, "country" => "China",
      "status" => "configured_convention", "convention" => "2156 BCE = year 1",
      "calendar_frame" => nil
    },
    {
      "key" => "gonghe", "label" => "共和紀年", "aliases" => ["共和紀年", "共和纪年"],
      "epoch_year" => -841, "epoch_number" => 1, "country" => "China",
      "status" => "configured_convention", "convention" => "841 BCE = year 1",
      "calendar_frame" => nil
    },
    {
      "key" => "confucius", "label" => "孔子紀年", "aliases" => ["孔子紀年", "孔子纪年"],
      "epoch_year" => -551, "epoch_number" => 1, "country" => "China",
      "status" => "configured_convention", "convention" => "551 BCE = year 1",
      "calendar_frame" => nil
    },
    {
      "key" => "unity", "label" => "統一紀年", "aliases" => ["統一紀年", "统一纪年"],
      "epoch_year" => -221, "epoch_number" => 1, "country" => "China",
      "status" => "configured_convention", "convention" => "221 BCE = year 1",
      "calendar_frame" => nil
    }
  ].map(&:freeze).freeze

  YEAR_SYSTEMS_BY_KEY = YEAR_SYSTEMS.to_h { |system| [system.fetch("key"), system] }.freeze

  CALENDAR_FRAMES = {
    "gregorian" => { "label" => "Gregorian", "when_frame" => "Gregorian", "backend" => "when_exe" },
    "julian" => { "label" => "Julian", "when_frame" => "Julian", "backend" => "when_exe" },
    "hebrew" => { "label" => "Hebrew / Jewish", "when_frame" => "Jewish", "backend" => "when_exe" },
    "islamic_tabular" => { "label" => "Islamic / Hijri (tabular)", "when_frame" => "TabularIslamic", "backend" => "when_exe" },
    "chinese_modern" => {
      "label" => "Chinese lunisolar (modern calculation)", "backend" => "lunar_calendar",
      "note" => "Uses the existing lunar_calendar data set (supported Gregorian years 1888–2100)."
    }
  }.transform_values(&:freeze).freeze

  # Explicit frame names accepted when a source category/title contains a full
  # non-Gregorian date. Bare numeric dates keep their existing Gregorian
  # interpretation; a non-Gregorian conversion is attempted only when the
  # source names the frame, so migration never guesses a calendar.
  CALENDAR_FRAME_ALIASES = {
    "gregorian" => ["Gregorian", "Gregorian calendar", "格里曆", "格里历", "公曆", "公历"],
    "julian" => ["Julian", "Julian calendar", "儒略曆", "儒略历"],
    "hebrew" => ["Hebrew", "Hebrew calendar", "Jewish", "Jewish calendar", "希伯來曆", "希伯来历", "猶太曆", "犹太历"],
    "islamic_tabular" => ["Hijri", "Hijri calendar", "Islamic", "Islamic calendar", "伊斯蘭曆", "伊斯兰历", "回曆", "回历"]
  }.transform_values { |values| values.freeze }.freeze

  class << self
    def call(operation: :resolve, value: nil, **options)
      new.call(operation: operation, value: value, **options)
    rescue ArgumentError, Date::Error => e
      {
        "resolved" => false,
        "operation" => operation.to_s,
        "original" => value.to_s,
        "error" => e.message
      }
    end
  end

  def call(operation:, value:, **options)
    case operation.to_s
    when "resolve"
      resolve(
        value,
        system: options[:system],
        context: options[:context] || {},
        authority: options[:authority] == true
      )
    when "represent"
      represent(value, include_before_epoch: options[:include_before_epoch] == true)
    when "resolve_prefix"
      resolve_prefix(
        value,
        context: options[:context] || {},
        authority: options[:authority] == true
      )
    when "convert"
      convert(value, from: options[:from] || "gregorian", to: options[:to] || "gregorian", leap: options[:leap] == true)
    when "era_convert"
      era_convert(
        value,
        direction: options[:direction],
        country: options[:country],
        polity: options[:polity],
        period: options[:period]
      )
    when "period_bounds"
      period_bounds(value)
    when "lookup"
      lookup_nomenclature(value, context: options[:context] || {}) || {
        "resolved" => false,
        "operation" => "lookup",
        "original" => value.to_s,
        "error" => "No configured sexagenary or 《爾雅》 nomenclature matched."
      }
    when "systems"
      systems
    else
      raise ArgumentError, "Unsupported calendar-engine operation: #{operation.inspect}"
    end
  end

  private

  def period_bounds(value)
    labels = value.is_a?(Array) ? value : [value]
    labels = labels.map { |item| item.to_s.strip }.reject(&:empty?)
    raise ArgumentError, "Enter a period or corpus-path label." if labels.empty?
    unless defined?(CbdbAutoAnnotatorStaticNames::PERIOD_RANGES)
      raise ArgumentError, "Historical period ranges are unavailable."
    end

    context = nil
    matched = []
    labels.each do |label|
      range = period_range_for_label(label)
      next unless range

      if context
        start_year = [context.fetch(:start), range.fetch(:start)].max
        end_year = [context.fetch(:end), range.fetch(:end)].min
        # A child folder can be homonymous with a later dynasty (for example
        # 戰國時代/宋). Such a range cannot replace the chronology already
        # established by its parents, so ignore that interpretation.
        next if start_year > end_year
        context = { start: start_year, end: end_year }
      else
        context = { start: range.fetch(:start), end: range.fetch(:end) }
      end
      matched << label
    end

    return {
      "resolved" => false,
      "operation" => "period_bounds",
      "kind" => "period_bounds",
      "original" => value,
      "error" => "No established historical period range matched."
    } unless context

    {
      "resolved" => true,
      "operation" => "period_bounds",
      "kind" => "period_bounds",
      "original" => value,
      "year_start" => context.fetch(:start),
      "year_end" => context.fetch(:end),
      "labels" => matched,
      "source" => "CbdbAutoAnnotatorStaticNames::PERIOD_RANGES"
    }
  end

  def period_range_for_label(value)
    forms = normalized_period_forms(value)
    CbdbAutoAnnotatorStaticNames::PERIOD_RANGES.each do |labels, start_year, end_year|
      next unless Array(labels).any? { |label| forms.include?(label.to_s) }
      return { start: Integer(start_year), end: Integer(end_year) }
    end
    nil
  end

  def normalized_period_forms(value)
    raw = value.to_s.strip
    return [] if raw.empty?

    output = [raw]
    output << raw.sub(/朝\z/, "") if raw.end_with?("朝")
    output << raw.each_char.drop(1).join if raw.start_with?("大") && raw.each_char.count > 1
    stripped = raw.sub(/\A大/, "").sub(/朝\z/, "")
    output << stripped unless stripped.empty?
    output.uniq
  end

  def systems
    {
      "resolved" => true,
      "operation" => "systems",
      "year_systems" => YEAR_SYSTEMS.map(&:dup),
      "calendar_frames" => CALENDAR_FRAMES.map { |key, data| data.merge("key" => key) }
    }
  end

  def resolve(value, system:, context:, authority: false)
    raw = value.to_s.strip
    raise ArgumentError, "Enter a date or calendrical expression." if raw.empty?

    requested_system = system.to_s.strip if system.respond_to?(:to_s)
    requested_system = nil if requested_system.to_s.empty?
    if requested_system && !YEAR_SYSTEMS_BY_KEY.key?(requested_system)
      raise ArgumentError, "Unknown year system: #{requested_system}"
    end

    named = resolve_named_year(raw, requested_system)
    return named if named

    framed = resolve_explicit_calendar_frame_date(raw)
    return framed if framed

    absolute = resolve_absolute_date(raw)
    return absolute if absolute

    nomenclature = lookup_nomenclature(raw, context: stringify_keys(context))
    return nomenclature if nomenclature

    authority_result = resolve_authority(raw, context) if authority
    return authority_result if authority_result

    {
      "resolved" => false,
      "operation" => "resolve",
      "original" => raw,
      "error" => "No configured deterministic calendar interpretation matched."
    }
  end

  # Resolve the longest leading substring that is itself one deterministic
  # absolute date. Corpus-maintenance callers use this to split metadata-like
  # date prefixes from source labels without copying any date syntax into Python.
  # Nomenclature-only results (for example 庚戌 or 柔兆敦牂) are deliberately
  # excluded because they do not identify an absolute date by themselves.
  def resolve_prefix(value, context:, authority: false)
    raw = value.to_s.strip
    raise ArgumentError, "Enter a date or calendrical expression." if raw.empty?

    characters = raw.each_char.to_a

    # First try the deterministic engine. This is cheap and covers all named
    # year systems plus ordinary Gregorian-style dates.
    characters.length.downto(1) do |length|
      prefix = characters.first(length).join.rstrip
      next if prefix.empty?

      result = resolve(prefix, system: nil, context: context, authority: false)
      next unless result["resolved"] && result["kind"] == "date" && result["year"]

      return prefix_result(raw, characters, length, prefix, result)
    end

    # Reign/regnal authority lookups are more expensive. A regnal year
    # expression must terminate at 年, so only those prefix boundaries are sent
    # to the authority resolver. This keeps corpus-maintenance scans fast while
    # preserving one calendrical implementation.
    if authority
      authority_lengths = characters.each_index.filter_map { |index| index + 1 if characters[index] == "年" }.reverse
      authority_lengths.each do |length|
        prefix = characters.first(length).join.rstrip
        result = resolve(prefix, system: nil, context: context, authority: true)
        next unless result["resolved"] && result["kind"] == "date" && result["year"]

        return prefix_result(raw, characters, length, prefix, result)
      end
    end

    {
      "resolved" => false,
      "operation" => "resolve_prefix",
      "original" => raw,
      "error" => "No leading deterministic or authority-backed date matched."
    }
  end

  def prefix_result(raw, characters, length, prefix, result)
    rest = characters.drop(length).join.strip
    result.merge(
      "operation" => "resolve_prefix",
      "original" => raw,
      "consumed" => prefix,
      "rest" => rest
    )
  end

  # Optional authority fallback for reign eras and ruler-regnal years. The
  # authority database remains owned by HistoricalDateResolver; CalendarEngine
  # is the public gateway and adapts its result into the common response shape.
  # The HistoricalDateResolver prepend calls back into CalendarEngine with the
  # default authority:false, so this delegation does not recurse indefinitely.
  def resolve_authority(raw, context)
    return nil unless raw.include?("年")
    return nil unless defined?(HistoricalDateResolver) && defined?(HistoricalAuthorityStore)

    context = stringify_keys(context)
    metadata = { "date_label" => raw }
    %w[corpus_root nation polity period region year_start year_end].each do |key|
      metadata[key] = context[key] if context[key].to_s != ""
    end
    metadata["nation"] ||= context["country"] if context["country"].to_s != ""

    resolution = HistoricalDateResolver.resolve(metadata: metadata)
    return nil unless resolution&.resolved?

    result = {
      "resolved" => true,
      "ambiguous" => false,
      "operation" => "resolve",
      "kind" => "date",
      "original" => raw,
      "source_system" => "historical_authority",
      "source_label" => resolution.authority_name,
      "authority_kind" => resolution.authority_kind,
      "authority_id" => resolution.authority_id,
      "country" => resolution.country,
      "confidence" => resolution.confidence,
      "year_start" => resolution.year_start,
      "year_end" => resolution.year_end,
      "candidates" => Array(resolution.candidates)
    }.compact

    if resolution.year_start && resolution.year_start == resolution.year_end
      result["year"] = resolution.year_start
      result["precision"] = "year"
    else
      result["precision"] = "range"
    end
    result
  rescue StandardError => e
    if defined?(Rails) && Rails.respond_to?(:logger)
      Rails.logger&.warn("[calendar] authority fallback skipped: #{e.class}: #{e.message}")
    end
    nil
  end

  def resolve_named_year(raw, requested_system)
    systems = if requested_system
      [YEAR_SYSTEMS_BY_KEY.fetch(requested_system)]
    else
      YEAR_SYSTEMS
    end

    candidates = systems.filter_map do |system|
      parsed = parse_named_year_for_system(raw, system)
      next unless parsed

      year_number = parsed.fetch(:year_number)
      absolute_year = absolute_year_for_number(system, year_number)
      next if absolute_year.zero?

      candidate = {
        "source_system" => system.fetch("key"),
        "source_label" => system.fetch("label"),
        "year_number" => year_number,
        "year" => absolute_year,
        "month" => parsed[:month],
        "day" => parsed[:day],
        "precision" => precision(parsed[:month], parsed[:day]),
        "country" => system["country"],
        "status" => system.fetch("status"),
        "convention" => system.fetch("convention"),
        "calendar_frame" => system["calendar_frame"]
      }.compact
      next unless valid_calendar_fields?(candidate.fetch("year"), candidate["month"], candidate["day"], frame: system["calendar_frame"])

      candidate
    end
    return nil if candidates.empty?

    candidates.uniq! { |candidate| [candidate.fetch("source_system"), candidate.fetch("year"), candidate["month"], candidate["day"]] }
    absolute_dates = candidates.map { |candidate| [candidate.fetch("year"), candidate["month"], candidate["day"]] }.uniq

    if absolute_dates.length == 1
      chosen = candidates.first
      return chosen.merge(
        "resolved" => true,
        "ambiguous" => false,
        "operation" => "resolve",
        "kind" => "date",
        "original" => raw,
        "confidence" => candidates.length == 1 ? "exact" : "convergent",
        "candidates" => candidates
      )
    end

    {
      "resolved" => false,
      "ambiguous" => true,
      "operation" => "resolve",
      "kind" => "date",
      "original" => raw,
      "confidence" => "ambiguous_convention",
      "candidates" => candidates
    }
  end

  def parse_named_year_for_system(raw, system)
    aliases = [system.fetch("label"), *system.fetch("aliases")].uniq.sort_by { |value| -value.length }
    aliases.each do |alias_name|
      match = raw.match(/\A#{Regexp.escape(alias_name)}\s*(#{NUMBER_CAPTURE})\s*年(?:\s*(#{NUMBER_CAPTURE})\s*月(?:\s*(#{NUMBER_CAPTURE})\s*日)?)?\z/i)
      next unless match

      year_number = parse_number(match[1])
      month = parse_number(match[2]) unless match[2].to_s.empty?
      day = parse_number(match[3]) unless match[3].to_s.empty?
      next unless year_number&.positive?

      return { year_number: year_number, month: month, day: day }
    end
    nil
  end


  def resolve_explicit_calendar_frame_date(raw)
    parsed = explicit_calendar_frame_date(raw)
    return nil unless parsed

    frame_key = parsed.fetch(:frame)
    fields = parsed.fetch(:fields)
    source_definition = CALENDAR_FRAMES.fetch(frame_key)

    if frame_key == "gregorian"
      raise ArgumentError, "Invalid Gregorian date." unless valid_calendar_fields?(*fields, frame: "gregorian")
      result_year, result_month, result_day = fields
      backend = "calendar_engine"
    else
      converted = convert(
        numeric_calendar_date(*fields),
        from: frame_key,
        to: "gregorian",
        leap: false
      )
      result = converted.fetch("result")
      result_year = Integer(result.fetch("year"))
      result_month = Integer(result.fetch("month"))
      result_day = Integer(result.fetch("day"))
      backend = converted.fetch("backend")
    end

    {
      "resolved" => true,
      "ambiguous" => false,
      "operation" => "resolve",
      "kind" => "date",
      "original" => raw,
      "source_system" => frame_key,
      "source_label" => source_definition.fetch("label"),
      "calendar_frame" => frame_key,
      "source_date" => {
        "year" => fields[0],
        "month" => fields[1],
        "day" => fields[2]
      },
      "year" => result_year,
      "month" => result_month,
      "day" => result_day,
      "precision" => "day",
      "confidence" => "exact",
      "backend" => backend,
      "candidates" => []
    }
  end

  def explicit_calendar_frame_date(raw)
    CALENDAR_FRAME_ALIASES.each do |frame_key, aliases|
      aliases.sort_by { |value| -value.length }.each do |alias_name|
        escaped = Regexp.escape(alias_name)
        prefix = raw.match(/\A#{escaped}\s*(?:[:：]\s*)?(.+)\z/i)
        if prefix && (fields = parse_calendar_coordinate_date(prefix[1]))
          return { frame: frame_key, fields: fields }
        end

        parenthesized_suffix = raw.match(/\A(.+?)\s*[（(]\s*#{escaped}\s*[)）]\z/i)
        if parenthesized_suffix && (fields = parse_calendar_coordinate_date(parenthesized_suffix[1]))
          return { frame: frame_key, fields: fields }
        end

        bare_suffix = raw.match(/\A(.+?)\s*#{escaped}\z/i)
        if bare_suffix && (fields = parse_calendar_coordinate_date(bare_suffix[1]))
          return { frame: frame_key, fields: fields }
        end
      end
    end
    nil
  end

  def parse_calendar_coordinate_date(value)
    raw = value.to_s.strip
    if (numeric = raw.match(/\A(-?\d{1,6})[-\/]([0-9]{1,2})[-\/]([0-9]{1,2})\z/))
      year = Integer(numeric[1], 10)
      raise ArgumentError, "There is no historical year zero." if year.zero?
      month = Integer(numeric[2], 10)
      day = Integer(numeric[3], 10)
      return [year, month, day] if month.positive? && day.positive?
      return nil
    end

    written = raw.match(/\A(#{NUMBER_CAPTURE})\s*年\s*(#{NUMBER_CAPTURE})\s*月\s*(#{NUMBER_CAPTURE})\s*日\z/)
    return nil unless written

    year = parse_number(written[1])
    month = parse_number(written[2])
    day = parse_number(written[3])
    return nil unless year&.positive? && month&.positive? && day&.positive?

    [year, month, day]
  end

  def numeric_calendar_date(year, month, day)
    "#{year}-#{format('%02d', month)}-#{format('%02d', day)}"
  end

  def resolve_absolute_date(raw)
    if (match = raw.match(/\A([+-]?\d{4,})-(\d{2})-(\d{2})(?:T.*)?\z/))
      year = Integer(match[1], 10)
      month = Integer(match[2], 10)
      day = Integer(match[3], 10)
      raise ArgumentError, "There is no historical year zero." if year.zero?
      return nil unless valid_calendar_fields?(year, month, day, frame: "gregorian")

      return absolute_result(raw, year, month, day, "iso8601")
    end

    if (match = raw.match(/\A(?:BCE|BC)\s*(#{NUMBER_CAPTURE})\s*(?:年)?\z/i))
      number = parse_number(match[1])
      return absolute_result(raw, -number, nil, nil, "bce") if number&.positive?
    end
    if (match = raw.match(/\A(#{NUMBER_CAPTURE})\s*(?:BCE|BC)\s*(?:年)?\z/i))
      number = parse_number(match[1])
      return absolute_result(raw, -number, nil, nil, "bce") if number&.positive?
    end
    if (match = raw.match(/\A(?:公元前|前)\s*(#{NUMBER_CAPTURE})\s*年?\z/))
      number = parse_number(match[1])
      return absolute_result(raw, -number, nil, nil, "bce") if number&.positive?
    end

    if (match = raw.match(/\A(?:CE|AD)\s*(#{NUMBER_CAPTURE})\s*(?:年)?\z/i))
      number = parse_number(match[1])
      return absolute_result(raw, number, nil, nil, "ce") if number&.positive?
    end
    if (match = raw.match(/\A(#{NUMBER_CAPTURE})\s*(?:CE|AD)\s*(?:年)?\z/i))
      number = parse_number(match[1])
      return absolute_result(raw, number, nil, nil, "ce") if number&.positive?
    end
    if (match = raw.match(/\A公元\s*(#{NUMBER_CAPTURE})\s*年?\z/))
      number = parse_number(match[1])
      return absolute_result(raw, number, nil, nil, "ce") if number&.positive?
    end

    match = raw.match(/\A(#{NUMBER_CAPTURE})\s*年(?:\s*(#{NUMBER_CAPTURE})\s*月(?:\s*(#{NUMBER_CAPTURE})\s*日)?)?\z/)
    return nil unless match

    year = parse_number(match[1])
    month = parse_number(match[2]) unless match[2].to_s.empty?
    day = parse_number(match[3]) unless match[3].to_s.empty?
    return nil unless year&.positive?
    return nil unless valid_calendar_fields?(year, month, day, frame: "gregorian")

    absolute_result(raw, year, month, day, "gregorian")
  end

  def absolute_result(raw, year, month, day, source_system)
    {
      "resolved" => true,
      "ambiguous" => false,
      "operation" => "resolve",
      "kind" => "date",
      "original" => raw,
      "source_system" => source_system,
      "year" => year,
      "month" => month,
      "day" => day,
      "precision" => precision(month, day),
      "confidence" => "exact",
      "candidates" => []
    }.compact
  end

  def represent(value, include_before_epoch: false)
    base = resolve_absolute_date(value.to_s.strip)
    if base
      year = base.fetch("year")
      month = base["month"]
      day = base["day"]
    else
      year = parse_absolute_year_value(value)
      month = nil
      day = nil
    end

    representations = YEAR_SYSTEMS.filter_map do |system|
      number = number_for_absolute_year(system, year)
      next if !include_before_epoch && number < system.fetch("epoch_number")

      {
        "key" => system.fetch("key"),
        "label" => system.fetch("label"),
        "year_number" => number,
        "display" => named_year_display(system, number, month, day),
        "status" => system.fetch("status"),
        "convention" => system.fetch("convention")
      }
    end

    sexagenary = sexagenary_for_historical_year(year)
    erya = erya_year_for_sexagenary(sexagenary)
    result = {
      "resolved" => true,
      "operation" => "represent",
      "kind" => "representations",
      "original" => value.to_s,
      "year" => year,
      "month" => month,
      "day" => day,
      "precision" => precision(month, day),
      "year_systems" => representations,
      "sexagenary_year" => sexagenary,
      "sexagenary_cycle_number" => sexagenary_entry(sexagenary)&.fetch("cycle_number"),
      "erya_year" => erya,
      "erya_source" => ERYA_SOURCE
    }.compact

    if month && day
      result["calendar_frames"] = calendar_frame_representations(year, month, day)
    end
    result
  end


  def calendar_frame_representations(year, month, day)
    input = format("%04d-%02d-%02d", year, month, day)
    rows = [{
      "key" => "gregorian",
      "label" => CALENDAR_FRAMES.fetch("gregorian").fetch("label"),
      "backend" => "when_exe",
      "display" => input,
      "year" => year, "month" => month, "day" => day
    }]

    %w[julian hebrew islamic_tabular].each do |key|
      converted = convert(input, from: "gregorian", to: key, leap: false)
      row = converted.fetch("result").merge(
        "key" => key,
        "label" => CALENDAR_FRAMES.fetch(key).fetch("label"),
        "backend" => converted.fetch("backend")
      )
      rows << row
    rescue ArgumentError => e
      rows << { "key" => key, "label" => CALENDAR_FRAMES.fetch(key).fetch("label"), "error" => e.message }
    end

    if year.between?(1888, 2100)
      lunar = modern_chinese_date(year, month, day)
      rows << lunar.merge(
        "key" => "chinese_modern",
        "label" => CALENDAR_FRAMES.fetch("chinese_modern").fetch("label"),
        "display" => chinese_lunar_display(lunar),
        "note" => CALENDAR_FRAMES.fetch("chinese_modern")["note"]
      )
    end
    rows
  end

  def chinese_lunar_display(lunar)
    leap = lunar["leap"] ? "閏" : ""
    "#{lunar['sexagenary_year']}年 #{leap}#{lunar['month']}月#{lunar['day']}日"
  end

  def convert(value, from:, to:, leap:)
    from_key = from.to_s
    to_key = to.to_s
    raise ArgumentError, "Unknown source calendar frame: #{from_key}" unless CALENDAR_FRAMES.key?(from_key)
    raise ArgumentError, "Unknown target calendar frame: #{to_key}" unless CALENDAR_FRAMES.key?(to_key)
    raise ArgumentError, "Chinese lunisolar input is not supported by lunar_calendar's public API." if from_key == "chinese_modern"

    fields = parse_numeric_date(value)
    raise ArgumentError, "Enter a complete numeric date such as 2026-08-28." unless fields

    if to_key == "chinese_modern"
      raise ArgumentError, "Chinese modern conversion currently accepts Gregorian input." unless from_key == "gregorian"
      raise ArgumentError, "Enter a valid Gregorian date." unless valid_calendar_fields?(*fields, frame: "gregorian")
      lunar = modern_chinese_date(*fields)
      return {
        "resolved" => true,
        "operation" => "convert",
        "kind" => "calendar_date",
        "original" => value.to_s,
        "from" => from_key,
        "to" => to_key,
        "backend" => "lunar_calendar",
        "result" => lunar
      }
    end

    require "when_exe"
    source_definition = CALENDAR_FRAMES.fetch(from_key)
    target_definition = CALENDAR_FRAMES.fetch(to_key)
    backend_fields = fields.dup
    if %w[gregorian julian].include?(from_key)
      backend_fields[0] = astronomical_year(fields[0])
    end
    begin
      source = When.tm_pos(*backend_fields, frame: source_definition.fetch("when_frame"))
      converted = When.Calendar(target_definition.fetch("when_frame")) ^ source
      coordinates = converted.cal_date
    rescue StandardError => e
      raise ArgumentError, "Invalid #{source_definition.fetch('label')} date: #{e.message}"
    end

    converted_year = coordinate_value(coordinates[0])
    if %w[gregorian julian].include?(to_key) && converted_year.is_a?(Integer)
      converted_year = historical_year(converted_year)
    end

    {
      "resolved" => true,
      "operation" => "convert",
      "kind" => "calendar_date",
      "original" => value.to_s,
      "from" => from_key,
      "to" => to_key,
      "backend" => "when_exe",
      "result" => {
        "year" => converted_year,
        "month" => coordinate_value(coordinates[1]),
        "day" => coordinate_value(coordinates[2]),
        "display" => converted.to_s,
        "frame" => target_definition.fetch("label")
      }
    }
  rescue LoadError => e
    raise ArgumentError, "when_exe is not installed yet (#{e.message}). Run bundle install."
  end

  # Compatibility doorway to the existing authority-backed regnal calendar
  # converter. Its mature authority/query code stays where it is; callers still
  # enter through CalendarEngine.call, so there is one public calendar gateway.
  def era_convert(value, direction:, country:, polity:, period:)
    raise ArgumentError, "Historical era converter is unavailable." unless defined?(EraCalendarConverter)

    EraCalendarConverter.convert(
      direction: direction,
      input: value,
      country: country,
      polity: polity,
      period: period
    ).merge("operation" => "era_convert")
  end

  def lookup_nomenclature(value, context:)
    raw = value.to_s.strip
    return nil if raw.empty?
    context = stringify_keys(context)

    if (cycle = sexagenary_entry(raw))
      scope = context["cycle_scope"].to_s
      result = {
        "resolved" => true,
        "ambiguous" => false,
        "operation" => "lookup",
        "kind" => "sexagenary_cycle",
        "original" => raw,
        "sexagenary" => cycle.fetch("name"),
        "cycle_number" => cycle.fetch("cycle_number"),
        "stem" => cycle.fetch("stem"),
        "branch" => cycle.fetch("branch"),
        "precision" => "cycle_position",
        "confidence" => "exact_cycle_identity"
      }
      if scope == "shang_day"
        result["cycle_scope"] = "day"
        result["source"] = SHANG_CYCLE_SOURCE
      end
      return result
    end

    if (erya = parse_erya_year_name(raw))
      return {
        "resolved" => true,
        "ambiguous" => false,
        "operation" => "lookup",
        "kind" => "erya_sexagenary_year_name",
        "original" => raw,
        "sexagenary" => erya.fetch("sexagenary"),
        "cycle_number" => erya.fetch("cycle_number"),
        "erya_year_name" => raw,
        "precision" => "cycle_position",
        "confidence" => "exact_nomenclature",
        "source" => ERYA_SOURCE,
        "note" => "This identifies a repeating sexagenary designation; it does not by itself identify one absolute year."
      }
    end

    if (erya_month = parse_erya_month_pair(raw))
      return erya_month.merge(
        "resolved" => true,
        "ambiguous" => false,
        "operation" => "lookup",
        "kind" => "erya_month_name",
        "original" => raw,
        "precision" => "month_nomenclature",
        "confidence" => "exact_nomenclature",
        "source" => ERYA_SOURCE,
        "note" => "The name identifies month/stem nomenclature; an absolute date still requires calendar context."
      )
    end

    if context["nomenclature"] == "erya_month"
      month = erya_month_number(raw)
      return nil unless month
      return {
        "resolved" => true,
        "ambiguous" => false,
        "operation" => "lookup",
        "kind" => "erya_month_name",
        "original" => raw,
        "month" => month,
        "erya_month" => raw,
        "precision" => "month_nomenclature",
        "confidence" => "context_required",
        "source" => ERYA_SOURCE
      }
    end

    nil
  end

  def parse_erya_year_name(raw)
    SEXAGENARY_NAMES.each_with_index do |name, index|
      stem, branch = name.each_char.to_a
      erya = "#{ERYA_YEAR_STEMS.fetch(stem)}#{ERYA_YEAR_BRANCHES.fetch(branch)}"
      return { "sexagenary" => name, "cycle_number" => index + 1 } if raw == erya
    end
    nil
  end

  def erya_year_for_sexagenary(name)
    cycle = sexagenary_entry(name)
    return nil unless cycle

    "#{ERYA_YEAR_STEMS.fetch(cycle.fetch('stem'))}#{ERYA_YEAR_BRANCHES.fetch(cycle.fetch('branch'))}"
  end

  def parse_erya_month_pair(raw)
    stem_match = ERYA_MONTH_STEMS.find { |_stem, alias_name| raw.start_with?(alias_name) }
    return nil unless stem_match

    stem, stem_alias = stem_match
    month_alias = raw.delete_prefix(stem_alias)
    month = erya_month_number(month_alias)
    return nil unless month

    {
      "month_stem" => stem,
      "erya_month_stem" => stem_alias,
      "month" => month,
      "erya_month" => month_alias
    }
  end

  def erya_month_number(value)
    raw = value.to_s
    ERYA_MONTH_NAMES.key(raw) || ERYA_MONTH_VARIANTS[raw]
  end

  def sexagenary_entry(value)
    name = value.to_s.strip.sub(/[日年月]\z/, "")
    index = SEXAGENARY_NAMES.index(name)
    return nil unless index

    {
      "name" => name,
      "cycle_number" => index + 1,
      "stem" => name.each_char.first,
      "branch" => name.each_char.drop(1).first
    }
  end

  def sexagenary_for_historical_year(year)
    astronomical = astronomical_year(Integer(year))
    SEXAGENARY_NAMES[(astronomical - 4) % 60]
  end

  def parse_absolute_year_value(value)
    return Integer(value) if value.is_a?(Integer)

    raw = value.to_s.strip
    if (match = raw.match(/\A(\d{1,6})\s*(?:BCE|BC)\z/i))
      return -Integer(match[1], 10)
    end
    if (match = raw.match(/\A(\d{1,6})\s*(?:CE|AD)?\z/i))
      year = Integer(match[1], 10)
      raise ArgumentError, "There is no historical year zero." if year.zero?
      return year
    end
    raise ArgumentError, "Enter one absolute year or a complete configured date."
  end

  def absolute_year_for_number(system, number)
    epoch_astronomical = astronomical_year(system.fetch("epoch_year"))
    astronomical = epoch_astronomical + (Integer(number) - system.fetch("epoch_number"))
    historical_year(astronomical)
  end

  def number_for_absolute_year(system, year)
    astronomical_year(Integer(year)) - astronomical_year(system.fetch("epoch_year")) + system.fetch("epoch_number")
  end

  def astronomical_year(historical)
    raise ArgumentError, "There is no historical year zero." if historical.zero?
    historical.negative? ? historical + 1 : historical
  end

  def historical_year(astronomical)
    astronomical <= 0 ? astronomical - 1 : astronomical
  end

  def named_year_display(system, number, month, day)
    year_text = number == 1 ? "元年" : "#{number}年"
    value = "#{system.fetch('label')}#{year_text}"
    value += "#{month}月" if month
    value += "#{day}日" if day
    value
  end

  def modern_chinese_date(year, month, day)
    require "lunar_calendar"
    raise ArgumentError, "lunar_calendar supports Gregorian years 1888–2100." unless year.between?(1888, 2100)

    lunar = LunarCalendar.at_lunar(year, month, day)
    sexagenary = lunar.respond_to?(:chinese_era) ? lunar.chinese_era.to_s : nil
    {
      "year" => lunar.year,
      "month" => lunar.month,
      "day" => lunar.day,
      "leap" => (lunar.respond_to?(:leap?) && lunar.leap?),
      "sexagenary_year" => sexagenary,
      "erya_year" => erya_year_for_sexagenary(sexagenary),
      "erya_month" => ERYA_MONTH_NAMES[lunar.month],
      "backend" => "lunar_calendar"
    }.compact
  rescue LoadError => e
    raise ArgumentError, "lunar_calendar is unavailable (#{e.message})."
  end

  def parse_numeric_date(value)
    raw = value.to_s.strip
    match = raw.match(/\A(-?\d{1,6})-(\d{1,2})-(\d{1,2})\z/)
    return nil unless match

    year = Integer(match[1], 10)
    raise ArgumentError, "There is no historical year zero." if year.zero?
    month = Integer(match[2], 10)
    day = Integer(match[3], 10)
    return nil unless month.positive? && day.positive?

    # Calendar-specific validity belongs to the selected backend. This parser
    # only separates numeric coordinates; it must not impose Gregorian month or
    # leap-day rules on Julian, Hebrew, or Islamic input.
    [year, month, day]
  end

  def valid_calendar_fields?(year, month, day, frame:)
    return false if year.to_i.zero?
    return true if month.nil? && day.nil?
    return false unless month&.between?(1, 12)
    return true if day.nil?
    return false unless day.between?(1, 31)

    if frame == "gregorian"
      astronomical = astronomical_year(year)
      return Date.valid_date?(astronomical, month, day)
    end
    true
  end

  def precision(month, day)
    return "day" if day
    return "month" if month
    "year"
  end

  def coordinate_value(value)
    return value.to_i if value.respond_to?(:to_i)
    value.to_s
  end

  def parse_number(value)
    text = value.to_s.strip
    return nil if text.empty?
    return 1 if text == "元"
    return Integer(text, 10) if text.match?(/\A\d+\z/)

    normalized = text.tr("兩两", "二二").gsub("廿", "二十").gsub("卅", "三十").gsub("卌", "四十")
    digits = {
      "〇" => 0, "零" => 0, "○" => 0, "一" => 1, "二" => 2, "三" => 3,
      "四" => 4, "五" => 5, "六" => 6, "七" => 7, "八" => 8, "九" => 9
    }
    if normalized.each_char.all? { |char| digits.key?(char) }
      return normalized.each_char.reduce(0) { |number, char| number * 10 + digits.fetch(char) }
    end

    small_units = { "十" => 10, "百" => 100, "千" => 1000 }
    total = 0
    section = 0
    current = 0
    normalized.each_char do |char|
      if digits.key?(char)
        current = digits.fetch(char)
      elsif small_units.key?(char)
        section += (current.zero? ? 1 : current) * small_units.fetch(char)
        current = 0
      elsif %w[萬 万].include?(char)
        section += current
        total += section * 10_000
        section = 0
        current = 0
      else
        return nil
      end
    end
    total + section + current
  rescue ArgumentError
    nil
  end

  def stringify_keys(hash)
    hash.to_h.each_with_object({}) { |(key, value), memo| memo[key.to_s] = value }
  end
end
