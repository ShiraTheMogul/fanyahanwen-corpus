# frozen_string_literal: true

require "json"
require "set"

# Resolves East Asian era-year and ruler-regnal-year expressions into absolute
# years. It deliberately returns nil when the surviving authority candidates
# remain genuinely ambiguous.
class HistoricalDateResolver
  NUMERAL_PATTERN = "元〇零○一二三四五六七八九十百千兩两廿卅卌0123456789"
  YEAR_EXPRESSION = /([^年]{1,48})年/
  MAX_ERA_NAME_LENGTH = 8
  MAX_RULER_NAME_LENGTH = 12
  SEXAGENARY_SUFFIX = /[甲乙丙丁戊己庚辛壬癸][子丑好寅卯榮荣辰巳午未申酉戌亥開开]\z/

  COUNTRY_HINTS = {
    "日本" => "Japan",
    "日本漢文" => "Japan",
    "Japan" => "Japan",
    "朝鮮" => "Korea",
    "朝鮮漢文" => "Korea",
    "韓國" => "Korea",
    "大韓" => "Korea",
    "Korea" => "Korea",
    "越南" => "Vietnam",
    "越南漢文" => "Vietnam",
    "大越" => "Vietnam",
    "Vietnam" => "Vietnam",
    "中國" => "China",
    "中國漢文" => "China",
    "四庫全書" => "China",
    "China" => "China"
  }.freeze

  Resolution = Data.define(
    :year_start, :year_end, :date_label, :source, :authority_kind,
    :authority_id, :authority_name, :country, :confidence, :candidates
  ) do
    def resolved? = !year_start.nil? || !year_end.nil?

    def to_h
      {
        "year_start" => year_start,
        "year_end" => year_end,
        "date_label" => date_label,
        "source" => source,
        "authority_kind" => authority_kind,
        "authority_id" => authority_id,
        "authority_name" => authority_name,
        "country" => country,
        "confidence" => confidence,
        "candidates" => candidates
      }.compact
    end
  end

  def self.resolve(metadata:, store: HistoricalAuthorityStore.default)
    new(store: store).resolve(metadata: metadata)
  end

  def initialize(store: HistoricalAuthorityStore.default)
    @store = store
    @expander = AuthorityNameExpander.new
    @era_candidate_cache = {}
    @ruler_candidate_cache = {}
  end

  def resolve(metadata:)
    data = metadata.to_h.stringify_keys
    explicit_start = integer_or_nil(data["year_start"] || data["year"])
    explicit_end = integer_or_nil(data["year_end"] || data["year"])
    if explicit_start || explicit_end
      return Resolution.new(
        year_start: explicit_start || explicit_end,
        year_end: explicit_end || explicit_start,
        date_label: data["date_label"].to_s.presence || data["date_text"].to_s.presence,
        source: "metadata",
        authority_kind: nil,
        authority_id: nil,
        authority_name: nil,
        country: context_country(data),
        confidence: "explicit",
        candidates: []
      )
    end

    text = [data["date_label"], data["date_text"]].map(&:to_s).reject(&:empty?).uniq.join(" ")
    return nil if text.empty?

    context = build_context(data)
    absolute = resolve_absolute_label(text, context)
    return absolute if absolute&.resolved?
    return nil unless @store.available?

    expressions(text).each do |expression|
      era = resolve_era_expression(expression, context)
      return era if era&.resolved?

      regnal = resolve_regnal_expression(expression, context)
      return regnal if regnal&.resolved?
    end
    nil
  rescue StandardError => e
    Rails.logger&.warn("[authority] historical date resolution skipped: #{e.class}: #{e.message}") if defined?(Rails)
    nil
  end

  # Diagnostic companion for the interactive calendar tool. Unlike #resolve,
  # this returns every era authority that matches the expression, including
  # candidates whose computed year falls outside that authority's use interval.
  # Production metadata dating continues to use #resolve and therefore remains
  # conservative/ambiguity-rejecting.
  def era_candidates_for(metadata:)
    data = metadata.to_h.stringify_keys
    text = [data["date_label"], data["date_text"]].map(&:to_s).reject(&:empty?).uniq.join(" ")
    return [] if text.empty? || !@store.available?

    context = build_context(data)
    expressions(text).flat_map do |expression|
      era_resolution_candidates(expression, context, include_out_of_range: true).map do |candidate|
        public_candidate(candidate).merge(
          "surface" => expression.fetch("surface"),
          "within_use" => candidate.fetch("within_use")
        )
      end
    end
  rescue StandardError => e
    Rails.logger&.warn("[authority] era diagnostics skipped: #{e.class}: #{e.message}") if defined?(Rails)
    []
  end

  private

  def resolve_absolute_label(text, context)
    raw = text.to_s.strip
    return nil if raw.empty? || raw.match?(/\A(?:不詳|不详|unknown|undated|n\.d\.)\z/i)

    start_year = nil
    end_year = nil
    source = "date_label_absolute"
    confidence = "explicit_label"

    # ISO timestamps occur in generated/modern corpus metadata. Only the year is
    # needed by the search manifest, but retain the original label untouched.
    if (match = raw.match(/\A([+-]?\d{4})-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?)?\z/))
      start_year = end_year = match[1].to_i
      source = "date_label_iso8601"
    elsif (range = historical_year_range(raw))
      start_year, end_year = range
      confidence = raw.match?(/\b(?:c\.?|ca\.?|circa)\b|[約约頃顷]/i) ? "approximate_label" : "explicit_label"
    elsif (year = historical_single_year(raw))
      start_year = end_year = year
      confidence = raw.match?(/\b(?:c\.?|ca\.?|circa)\b|[約约頃顷]/i) ? "approximate_label" : "explicit_label"
    elsif (han_year = han_digit_calendar_year(raw))
      start_year = end_year = han_year
    else
      return nil
    end

    Resolution.new(
      year_start: start_year,
      year_end: end_year,
      date_label: raw,
      source: source,
      authority_kind: nil,
      authority_id: nil,
      authority_name: nil,
      country: context[:country],
      confidence: confidence,
      candidates: []
    )
  end

  def historical_year_range(value)
    text = value.to_s.strip.gsub(/[−‐‑‒–—]/, "-")
    match = text.match(/\A(?:c\.?|ca\.?|circa|約|约)?\s*(\d{1,4})\s*(BC|BCE|AD|CE)?\s*年?\s*-\s*(\d{1,4})\s*(BC|BCE|AD|CE)?\s*(?:年)?\s*(?:頃|顷|左右)?\z/i)
    return nil unless match

    shared_era = match[4].to_s.presence || match[2].to_s.presence
    left = signed_year(match[1], match[2].presence || shared_era)
    right = signed_year(match[3], match[4].presence || shared_era)
    return nil unless left && right

    left <= right ? [left, right] : [right, left]
  end

  def historical_single_year(value)
    text = value.to_s.strip
    patterns = [
      /\A(?:c\.?|ca\.?|circa|約|约)?\s*(\d{1,4})\s*(BC|BCE|AD|CE)\s*(?:年)?\s*(?:頃|顷|左右)?\z/i,
      /\A(?:BC|BCE)\s*(\d{1,4})\s*(?:年)?\z/i,
      /\A(?:AD|CE)\s*(\d{1,4})\s*(?:年)?\z/i,
      /\A公元前\s*(\d{1,4})\s*年?\z/,
      /\A公元\s*(\d{1,4})\s*年?\z/,
      /\A前\s*(\d{1,4})\s*年?\z/,
      /\A(?:c\.?|ca\.?|circa|約|约)?\s*(\d{1,4})\s*(?:年(?:\s*\d{1,2}\s*月(?:\s*\d{1,2}\s*日)?)?)?\s*(?:頃|顷|左右)?\z/i
    ]

    patterns.each_with_index do |pattern, index|
      match = text.match(pattern)
      next unless match

      return -match[1].to_i if index == 1 || index == 3 || index == 5
      return match[1].to_i if index == 2 || index == 4 || index == 6
      return signed_year(match[1], match[2]) if index == 0
    end
    nil
  end

  def han_digit_calendar_year(value)
    text = value.to_s.strip
    match = text.match(/\A([〇零○一二三四五六七八九]{2,4})\s*年(?:\s*[〇零○一二三四五六七八九十]{1,3}\s*月(?:\s*[〇零○一二三四五六七八九十]{1,3}\s*日)?)?\z/)
    return nil unless match

    chinese_number(match[1])
  end

  def signed_year(number, era)
    year = Integer(number)
    era.to_s.upcase.match?(/\A(?:BC|BCE)\z/) ? -year : year
  rescue ArgumentError, TypeError
    nil
  end

  def expressions(text)
    text.to_enum(:scan, YEAR_EXPRESSION).filter_map do
      match = Regexp.last_match
      split = split_year_expression(match[1])
      next unless split

      prefix, numeral, year_number = split
      {
        "prefix" => prefix,
        "year_number" => year_number,
        "surface" => "#{prefix}#{numeral}年"
      }
    end
  end

  def split_year_expression(value)
    raw = value.to_s.rstrip
    chars = raw.each_char.to_a
    return nil if chars.length < 2

    finish = chars.length
    start = finish
    start -= 1 while start.positive? && numeral_character?(chars[start - 1])
    return nil if start == finish

    # 元 is both a frequent era-name graph and the conventional first-year
    # numeral. Try the longest numeric-looking suffix first and progressively
    # shorten it until it parses, rather than letting a greedy regexp split
    # 開國五百三年 as 開國五百 + 三年.
    (start...finish).each do |number_start|
      numeral = chars[number_start...finish].join
      year_number = chinese_number(numeral)
      next unless year_number&.positive?

      prefix = chars[0...number_start].join.rstrip
      next unless prefix.match?(/\p{Han}/)
      return [prefix, numeral, year_number]
    end
    nil
  end

  def numeral_character?(character)
    NUMERAL_PATTERN.include?(character.to_s)
  end

  def resolve_era_expression(expression, context)
    scored = era_resolution_candidates(expression, context).select { |candidate| candidate.fetch("score") > -100 }
    choose_resolution(scored, expression, authority_kind: "era")
  end

  def era_resolution_candidates(expression, context, include_out_of_range: false)
    prefix = expression.fetch("prefix")
    year_number = expression.fetch("year_number")
    name, candidates = longest_matching_era_suffix(prefix)
    return [] if candidates.empty?

    candidates.filter_map do |candidate|
      base_year = integer_or_nil(candidate["epoch_start_year"] || candidate["start_year"])
      next unless base_year

      absolute_year = era_absolute_year(base_year, year_number)
      availability_start = integer_or_nil(candidate["local_use_start_year"] || candidate["start_year"])
      availability_end = integer_or_nil(candidate["local_use_end_year"] || candidate["end_year"]) || availability_start
      # Some calendars (notably Korea's 開國) deliberately back-date year one
      # to a dynastic foundation while only being used officially centuries
      # later. The epoch determines arithmetic; the use interval determines
      # whether that computed year is historically valid for this authority.
      within_use = !(availability_start && absolute_year < availability_start) &&
        !(availability_end && absolute_year > availability_end)
      next if !within_use && !include_out_of_range

      score = candidate_score(candidate, context, authority_kind: "era")
      score += adoption_support_score(candidate, candidates, absolute_year, context) if within_use

      candidate.merge(
        "matched_name" => name,
        "year_number" => year_number,
        "absolute_year" => absolute_year,
        "within_use" => within_use,
        "score" => score
      )
    end
  end

  def resolve_regnal_expression(expression, context)
    prefix = expression.fetch("prefix")
    year_number = expression.fetch("year_number")
    name, candidates = longest_matching_ruler_suffix(prefix)
    return nil if candidates.empty?

    scored = candidates.filter_map do |candidate|
      next unless candidate["year_start"]
      absolute_year = candidate["year_start"].to_i + year_number - 1
      next if candidate["year_end"] && absolute_year > candidate["year_end"].to_i

      score = candidate_score(candidate, context, authority_kind: "ruler")
      next if score <= -100

      candidate.merge(
        "matched_name" => name,
        "year_number" => year_number,
        "absolute_year" => absolute_year,
        "score" => score
      )
    end
    choose_resolution(scored, expression, authority_kind: "ruler")
  end

  def choose_resolution(candidates, expression, authority_kind:)
    return nil if candidates.empty?

    ordered = candidates.sort_by { |candidate| [-candidate.fetch("score"), candidate.fetch("absolute_year"), candidate.fetch("id").to_s] }
    best_score = ordered.first.fetch("score")
    leaders = ordered.select { |candidate| candidate.fetch("score") == best_score }
    years = leaders.map { |candidate| candidate.fetch("absolute_year") }.uniq
    return nil if years.length != 1

    chosen = leaders.max_by do |candidate|
      [candidate["explicit_name"] ? 1 : 0, candidate["source"] == "cbdb" ? 1 : 0]
    end
    absolute_year = years.first
    confidence = if chosen["chronology_confidence"].present?
      leaders.length == 1 ? "traditional" : "traditional_convergent"
    else
      leaders.length == 1 ? "high" : "convergent"
    end
    Resolution.new(
      year_start: absolute_year,
      year_end: absolute_year,
      date_label: expression.fetch("surface"),
      source: chosen.fetch("source"),
      authority_kind: authority_kind,
      authority_id: chosen.fetch("id"),
      authority_name: authority_display_name(chosen, authority_kind),
      country: chosen["country"],
      confidence: confidence,
      candidates: ordered.first(12).map { |candidate| public_candidate(candidate) }
    )
  end

  def authority_display_name(candidate, authority_kind)
    if authority_kind.to_s == "era"
      candidate["matched_name"].to_s.presence || candidate["name_chn"].to_s.presence || candidate["label"].to_s.presence
    else
      candidate["label"].to_s.presence || candidate["matched_name"].to_s.presence || candidate["name_chn"].to_s.presence
    end
  end

  def longest_matching_era_suffix(prefix)
    era_match_prefixes(prefix).each do |candidate_prefix|
      [MAX_ERA_NAME_LENGTH, candidate_prefix.each_char.count].min.downto(2) do |length|
        name = candidate_prefix.each_char.to_a.last(length).join
        rows = era_candidates(name)
        return [name, rows] if rows.any?
      end
    end
    [nil, []]
  end

  def era_match_prefixes(prefix)
    raw = prefix.to_s.rstrip
    stripped = raw.sub(SEXAGENARY_SUFFIX, "")
    [raw, stripped].reject(&:empty?).uniq
  end

  def longest_matching_ruler_suffix(prefix)
    [MAX_RULER_NAME_LENGTH, prefix.each_char.count].min.downto(2) do |length|
      name = prefix.each_char.to_a.last(length).join
      rows = ruler_candidates(name)
      return [name, rows] if rows.any?
    end
    [nil, []]
  end

  def era_candidates(name)
    key = name.to_s
    return @era_candidate_cache[key] if @era_candidate_cache.key?(key)

    @era_candidate_cache[key] = load_era_candidates(key).freeze
  end

  def load_era_candidates(name)
    forms = lookup_forms(name)
    rows = []
    @store.with_database do |db|
      if @store.historical_available?
        placeholders = (["?"] * forms.length).join(",")
        rows.concat(db.execute(<<~SQL, forms))
          SELECT e.source, e.era_id, e.country, e.origin_country, e.label, e.local_label,
                 e.start_year, e.end_year, e.epoch_start_year, e.local_use_start_year, e.local_use_end_year,
                 e.adopted_from_foreign, e.polities_json, e.source_url, e.source_note,
                 n.name_chn, n.explicit_name, n.derivation
          FROM historical.era_names n
          JOIN historical.eras e ON e.source = n.source AND e.era_id = n.era_id
          WHERE n.name_chn IN (#{placeholders})
        SQL
      end

      if @store.cbdb_available? && table_exists?(db, "cbdb", "NIAN_HAO")
        columns = table_columns(db, "cbdb", "NIAN_HAO")
        name_column = choose_column(columns, %w[c_nianhao_chn nianhao_chn])
        id_column = choose_column(columns, %w[c_nianhao_id nianhao_id])
        dynasty_column = choose_column(columns, %w[c_dynasty_chn dynasty_chn])
        start_column = choose_column(columns, %w[c_firstyear firstyear])
        end_column = choose_column(columns, %w[c_lastyear lastyear])
        if name_column && id_column && start_column
          placeholders = (["?"] * forms.length).join(",")
          select_dynasty = dynasty_column ? "#{quote_identifier(dynasty_column)} AS dynasty_chn" : "NULL AS dynasty_chn"
          select_end = end_column ? "#{quote_identifier(end_column)} AS end_year" : "NULL AS end_year"
          sql = <<~SQL
            SELECT #{quote_identifier(id_column)} AS era_id,
                   #{quote_identifier(name_column)} AS name_chn,
                   #{select_dynasty},
                   #{quote_identifier(start_column)} AS start_year,
                   #{select_end}
            FROM cbdb.NIAN_HAO
            WHERE #{quote_identifier(name_column)} IN (#{placeholders})
          SQL
          db.execute(sql, forms).each do |row|
            rows << {
              "source" => "cbdb",
              "era_id" => row["era_id"].to_s,
              "country" => "China",
              "label" => row["name_chn"].to_s,
              "start_year" => integer_or_nil(row["start_year"]),
              "end_year" => integer_or_nil(row["end_year"]),
              "dynasty" => row["dynasty_chn"].to_s.presence,
              "name_chn" => row["name_chn"].to_s,
              "explicit_name" => true,
              "derivation" => "cbdb_nianhao",
              "source_url" => HistoricalAuthorityStore::CBDB_URL
            }.compact
          end
        end
      end
    end
    normalize_era_rows(rows)
  end

  def ruler_candidates(name)
    key = name.to_s
    return @ruler_candidate_cache[key] if @ruler_candidate_cache.key?(key)

    @ruler_candidate_cache[key] = load_ruler_candidates(key).freeze
  end

  def load_ruler_candidates(name)
    return [] unless @store.historical_available?

    forms = lookup_forms(name)
    rows = []
    @store.with_database do |db|
      placeholders = (["?"] * forms.length).join(",")
      rows = db.execute(<<~SQL, forms)
        SELECT p.source, p.entity_id, p.country, p.label, p.local_label,
               p.year_start, p.year_end, p.date_label, p.polity, p.roles,
               p.source_url, p.chronology_confidence, n.name_chn, n.explicit_name, n.derivation
        FROM historical.names n
        JOIN historical.people p ON p.source = n.source AND p.entity_id = n.entity_id
        WHERE n.name_chn IN (#{placeholders})
          AND p.roles = 'ruler'
      SQL
    end
    rows.map do |row|
      {
        "source" => row["source"].to_s,
        "id" => row["entity_id"].to_s,
        "country" => row["country"].to_s.presence,
        "label" => row["label"].to_s.presence || row["name_chn"].to_s,
        "local_label" => row["local_label"].to_s.presence,
        "year_start" => integer_or_nil(row["year_start"]),
        "year_end" => integer_or_nil(row["year_end"]),
        "polity" => row["polity"].to_s.presence,
        "name_chn" => row["name_chn"].to_s,
        "explicit_name" => row["explicit_name"].to_i == 1,
        "derivation" => row["derivation"].to_s,
        "source_url" => row["source_url"].to_s.presence,
        "chronology_confidence" => row["chronology_confidence"].to_s.presence
      }.compact
    end
  end

  def normalize_era_rows(rows)
    rows.map do |row|
      if row.is_a?(Hash) && row.key?("era_id") && row.key?("source") && row["source"].to_s != "cbdb"
        {
          "source" => row["source"].to_s,
          "id" => row["era_id"].to_s,
          "country" => row["country"].to_s.presence,
          "origin_country" => row["origin_country"].to_s.presence,
          "label" => row["label"].to_s.presence || row["name_chn"].to_s,
          "local_label" => row["local_label"].to_s.presence,
          "start_year" => integer_or_nil(row["start_year"]),
          "end_year" => integer_or_nil(row["end_year"]),
          "epoch_start_year" => integer_or_nil(row["epoch_start_year"]),
          "local_use_start_year" => integer_or_nil(row["local_use_start_year"]),
          "local_use_end_year" => integer_or_nil(row["local_use_end_year"]),
          "adopted_from_foreign" => row["adopted_from_foreign"].to_i == 1,
          "polities" => parse_json_array(row["polities_json"]),
          "name_chn" => row["name_chn"].to_s,
          "explicit_name" => row["explicit_name"].to_i == 1,
          "derivation" => row["derivation"].to_s,
          "source_url" => row["source_url"].to_s.presence,
          "source_note" => row["source_note"].to_s.presence
        }.compact
      else
        normalized = row.to_h.dup
        normalized["id"] ||= normalized.delete("era_id")
        normalized
      end
    end.uniq { |row| [row["source"], row["id"], row["name_chn"]] }
  end

  def adoption_support_score(candidate, all_candidates, absolute_year, context)
    context_country = context[:country]
    return 0 unless context_country.present?

    supports = all_candidates.select do |support|
      next false unless support["adopted_from_foreign"] == true
      next false unless support["country"].to_s == context_country.to_s
      next false unless support["origin_country"].to_s == candidate["country"].to_s
      local_start = integer_or_nil(support["local_use_start_year"])
      local_end = integer_or_nil(support["local_use_end_year"]) || local_start
      local_start && local_end && absolute_year.between?(local_start, local_end)
    end
    supports.empty? ? 0 : 55
  end

  def candidate_score(candidate, context, authority_kind:)
    score = 60
    score += candidate["explicit_name"] == false ? 0 : 6
    score += authority_kind == "ruler" ? 4 : 0
    score -= 8 if authority_kind == "ruler" && candidate["chronology_confidence"].present?

    country = context.fetch(:country, nil)
    candidate_country = candidate["country"].to_s
    if country && !candidate_country.empty?
      if candidate_country == country
        score += 40
      elsif candidate_country == "China" && %w[Japan Korea Vietnam].include?(country)
        # Chinese era names were adopted outside China. Keep them viable and let
        # chronology/polity context decide instead of hard-filtering by nation.
        score -= 4
      else
        score -= 35
      end
    end

    context_start = context[:year_start]
    context_end = context[:year_end]
    candidate_start = integer_or_nil(candidate["local_use_start_year"] || candidate["start_year"] || candidate["year_start"])
    candidate_end = integer_or_nil(candidate["local_use_end_year"] || candidate["end_year"] || candidate["year_end"]) || candidate_start
    if (context_start || context_end) && candidate_start
      left = context_start || context_end
      right = context_end || context_start
      if candidate_end && candidate_end < left || candidate_start > right
        return -1_000
      end
      score += 70
    end

    context_words = context.fetch(:words)
    searchable = [candidate["dynasty"], candidate["polity"], *Array(candidate["polities"])].compact.map(&:to_s)
    score += 30 if searchable.any? { |value| !value.empty? && context_words.include?(value) }

    score
  end

  def build_context(data)
    {
      country: context_country(data),
      year_start: integer_or_nil(data["year_start"] || data["year"]),
      year_end: integer_or_nil(data["year_end"] || data["year"]),
      words: [data["period"], data["polity"], data["region"], data["corpus_root"], data["nation"]]
        .map(&:to_s).reject(&:empty?).join(" ")
    }
  end

  def context_country(data)
    text = [data["corpus_root"], data["nation"], data["polity"], data["period"], data["region"]].map(&:to_s).join(" ")
    COUNTRY_HINTS.each do |hint, country|
      return country if text.include?(hint)
    end
    nil
  end

  def lookup_forms(name)
    forms = [name]
    @expander.expand(name).each { |form| forms << form.name }
    forms.uniq.first(192)
  end

  def era_absolute_year(base_year, year_number)
    year = base_year.to_i + year_number.to_i - 1
    # Historical BCE/CE notation has no year zero. Our internal negative years
    # use -1 for 1 BCE, so an epoch that crosses into CE must skip zero.
    year += 1 if base_year.to_i.negative? && year >= 0
    year
  end

  def chinese_number(text)
    value = text.to_s
    return 1 if value == "元"
    return Integer(value, 10) if value.match?(/\A\d+\z/)

    # 廿三、卅二、卌五 occur routinely in historical dating. Expand the
    # shorthand before the normal Chinese-number parser instead of treating
    # only bare 廿/卅/卌 as special cases.
    value = value.sub(/\A廿/, "二十").sub(/\A卅/, "三十").sub(/\A卌/, "四十")

    digits = { "〇" => 0, "零" => 0, "○" => 0, "一" => 1, "二" => 2, "兩" => 2, "两" => 2,
               "三" => 3, "四" => 4, "五" => 5, "六" => 6, "七" => 7, "八" => 8, "九" => 9 }
    units = { "十" => 10, "百" => 100, "千" => 1000 }

    if value.each_char.all? { |char| digits.key?(char) }
      return value.each_char.reduce(0) { |memo, char| memo * 10 + digits.fetch(char) }
    end

    total = 0
    current = 0
    value.each_char do |char|
      if digits.key?(char)
        current = digits.fetch(char)
      elsif units.key?(char)
        unit = units.fetch(char)
        current = 1 if current.zero?
        total += current * unit
        current = 0
      else
        return nil
      end
    end
    total + current
  end

  def public_candidate(candidate)
    {
      "source" => candidate["source"],
      "id" => candidate["id"],
      "label" => candidate["label"],
      "country" => candidate["country"],
      "origin_country" => candidate["origin_country"],
      "start_year" => candidate["start_year"] || candidate["year_start"],
      "end_year" => candidate["end_year"] || candidate["year_end"],
      "epoch_start_year" => candidate["epoch_start_year"],
      "local_use_start_year" => candidate["local_use_start_year"],
      "local_use_end_year" => candidate["local_use_end_year"],
      "absolute_year" => candidate["absolute_year"],
      "year_number" => candidate["year_number"],
      "score" => candidate["score"],
      "matched_name" => candidate["matched_name"],
      "derivation" => candidate["derivation"],
      "explicit_name" => candidate["explicit_name"],
      "adopted_from_foreign" => candidate["adopted_from_foreign"],
      "polities" => candidate["polities"],
      "source_url" => candidate["source_url"],
      "source_note" => candidate["source_note"],
      "chronology_confidence" => candidate["chronology_confidence"]
    }.compact
  end

  def parse_json_array(value)
    parsed = JSON.parse(value.to_s)
    parsed.is_a?(Array) ? parsed : []
  rescue JSON::ParserError
    []
  end

  def table_exists?(db, schema, table)
    db.get_first_value("SELECT 1 FROM #{schema}.sqlite_master WHERE type='table' AND name = ? LIMIT 1", [table]).to_i == 1
  end

  def table_columns(db, schema, table)
    db.execute("PRAGMA #{schema}.table_info(#{quote_identifier(table)})").map { |row| row["name"].to_s }
  end

  def choose_column(columns, candidates)
    lookup = columns.to_h { |column| [column.downcase, column] }
    candidates.each do |candidate|
      return lookup[candidate.downcase] if lookup.key?(candidate.downcase)
    end
    nil
  end

  def quote_identifier(value)
    %Q{"#{value.to_s.gsub('"', '""')}"}
  end

  def integer_or_nil(value)
    Integer(value) if value.to_s.match?(/\A-?\d+\z/)
  rescue ArgumentError, TypeError
    nil
  end
end
