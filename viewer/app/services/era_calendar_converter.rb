# frozen_string_literal: true

require "json"

# Interactive, read-only calendar converter backed by the same historical
# authority data used by corpus metadata dating. This is intentionally a
# year-level converter: month/day conversion belongs to the separate lunar
# calendar tool because East Asian era years do not imply a Gregorian date.
class EraCalendarConverter
  COUNTRIES = %w[China Japan Korea Vietnam].freeze
  STEMS = %w[甲 乙 丙 丁 戊 己 庚 辛 壬 癸].freeze
  BRANCHES = %w[子 丑 寅 卯 辰 巳 午 未 申 酉 戌 亥].freeze
  TAIPING_BRANCHES = { "亥" => "開", "丑" => "好", "卯" => "榮" }.freeze

  SOURCE_DISPLAY = {
    "cbdb" => "CBDB",
    "wikidata_east_asia" => "Wikidata",
    "wikidata_east_asia+wikipedia_era_list" => "Wikidata + Wikipedia era list",
    "wikidata_east_asia+wikipedia_ruler_list" => "Wikidata + Wikipedia ruler list",
    "wikipedia_era_list" => "Wikipedia era list",
    "wikipedia_ruler_list" => "Wikipedia ruler list",
    "fanya_curated_era" => "Fanya curated authority"
  }.freeze

  COUNTRY_DISPLAY = {
    "China" => ["中國", "China"],
    "Japan" => ["日本", "Japan"],
    "Korea" => ["韓國", "Korea"],
    "Vietnam" => ["越南", "Vietnam"]
  }.freeze

  POLITY_DISPLAY = {
    "Japan" => ["日本", "Japan"],
    "Joseon" => ["朝鮮王朝", "Joseon dynasty"],
    "Joseon dynasty" => ["朝鮮王朝", "Joseon dynasty"],
    "Korean Empire" => ["大韓帝國", "Korean Empire"],
    "Goryeo" => ["高麗", "Goryeo"],
    "Balhae" => ["渤海", "Balhae"],
    "Silla" => ["新羅", "Silla"],
    "Unified Silla" => ["統一新羅", "Unified Silla"],
    "Goguryeo" => ["高句麗", "Goguryeo"],
    "Baekje" => ["百濟", "Baekje"],
    "Gaya" => ["伽倻", "Gaya"],
    "Nguyễn dynasty" => ["阮朝", "Nguyễn dynasty"],
    "Nguyen dynasty" => ["阮朝", "Nguyễn dynasty"],
    "Lê dynasty" => ["黎朝", "Lê dynasty"],
    "Later Lê dynasty" => ["後黎朝", "Later Lê dynasty"],
    "Early Lê dynasty" => ["前黎朝", "Early Lê dynasty"],
    "Lý dynasty" => ["李朝", "Lý dynasty"],
    "Trần dynasty" => ["陳朝", "Trần dynasty"],
    "Hồ dynasty" => ["胡朝", "Hồ dynasty"],
    "Mạc dynasty" => ["莫朝", "Mạc dynasty"],
    "Tây Sơn dynasty" => ["西山朝", "Tây Sơn dynasty"],
    "Đinh dynasty" => ["丁朝", "Đinh dynasty"],
    "Ngô dynasty" => ["吳朝", "Ngô dynasty"],
    "Nguyễn lords" => ["阮主", "Nguyễn lords"],
    "Trịnh lords" => ["鄭主", "Trịnh lords"],
    "Đại Việt" => ["大越", "Đại Việt"],
    "Dai Viet" => ["大越", "Đại Việt"],
    "Đại Cồ Việt" => ["大瞿越", "Đại Cồ Việt"],
    "Vietnam" => ["越南", "Vietnam"],
    "大西" => ["大西", "Daxi"],
    "大順" => ["大順", "Dashun"],
    "大順餘部" => ["大順餘部", "Dashun remnants"],
    "大顺余部" => ["大順餘部", "Dashun remnants"],
    "太平天國" => ["太平天國", "Taiping Heavenly Kingdom"],
    "太平天国" => ["太平天國", "Taiping Heavenly Kingdom"],
    "太平天國餘部" => ["太平天國餘部", "Taiping remnants"],
    "太平軍餘部" => ["太平軍餘部", "Taiping remnants"]
  }.freeze

  def self.convert(direction:, input:, country: nil, polity: nil, period: nil, store: HistoricalAuthorityStore.default)
    new(store: store).convert(
      direction: direction,
      input: input,
      country: country,
      polity: polity,
      period: period
    )
  end

  def initialize(store: HistoricalAuthorityStore.default)
    @store = store
    @resolver = HistoricalDateResolver.new(store: store)
  end

  def convert(direction:, input:, country: nil, polity: nil, period: nil)
    mode = direction.to_s == "absolute_to_era" ? "absolute_to_era" : "era_to_absolute"
    value = input.to_s.strip
    raise ArgumentError, "Enter a date or era-year expression." if value.empty?

    context = normalized_context(country: country, polity: polity, period: period)
    if mode == "absolute_to_era"
      reverse(value, context)
    else
      forward(value, context)
    end
  end

  private

  def forward(input, context)
    metadata = context_metadata(context).merge("date_label" => input)
    resolution = @resolver.resolve(metadata: metadata)
    candidates = @resolver.era_candidates_for(metadata: metadata)
    candidates = decorate_forward_candidates(candidates)
    resolution_hash = resolution&.to_h
    if resolution_hash.present? && resolution_hash["authority_kind"] == "era"
      winner = candidates.find do |candidate|
        candidate["source"].to_s == resolution_hash["source"].to_s &&
          candidate["id"].to_s == resolution_hash["authority_id"].to_s
      end
      resolution_hash["rulers"] = winner["rulers"] if winner&.dig("rulers").present?
      resolution_hash["country_display"] = winner["country_display"] if winner
      resolution_hash["polity_displays"] = winner["polity_displays"] if winner
    end

    {
      "direction" => "era_to_absolute",
      "input" => input,
      "context" => context,
      "resolution" => resolution_hash,
      "candidates" => candidates,
      "authority_available" => @store.available?
    }
  end

  def reverse(input, context)
    year = absolute_year_from_input(input, context)
    raise ArgumentError, "Enter one absolute year, for example 1853, 1853 CE, or 658 BCE." unless year
    raise ArgumentError, "There is no historical year zero." if year.zero?
    raise ArgumentError, "Historical authority data have not been built yet." unless @store.available?

    matches = reverse_candidates(year, context)
    {
      "direction" => "absolute_to_era",
      "input" => input,
      "absolute_year" => year,
      "absolute_year_label" => year_label(year),
      "context" => context,
      "matches" => matches,
      "authority_available" => true
    }
  end

  def absolute_year_from_input(input, context)
    stripped = input.to_s.strip
    if stripped.match?(/\A-?\d{1,4}\z/)
      return Integer(stripped, 10)
    end

    resolution = @resolver.resolve(metadata: context_metadata(context).merge("date_label" => stripped))
    return nil unless resolution&.resolved?
    return nil unless resolution.authority_kind.nil?
    return nil unless resolution.year_start == resolution.year_end

    resolution.year_start
  rescue ArgumentError, TypeError
    nil
  end

  def reverse_candidates(year, context)
    rows = []
    @store.with_database do |db|
      rows.concat(historical_reverse_candidates(db, year, context)) if @store.historical_available?
      rows.concat(cbdb_reverse_candidates(db, year, context)) if @store.cbdb_available? && context[:country].in?([nil, "China"])
    end

    rows
      .uniq { |row| [row["source"], row["id"], row["name_chn"], row["country"], row["polity"]] }
      .sort_by do |row|
        [
          country_sort(row, context),
          polity_sort(row, context),
          row["adopted_from_foreign"] ? 1 : 0,
          row["name_chn"].to_s,
          row["source"].to_s,
          row["id"].to_s
        ]
      end
  end

  def historical_reverse_candidates(db, year, context)
    rows = db.execute(<<~SQL, [year, year])
      SELECT e.*
      FROM historical.eras e
      WHERE COALESCE(e.local_use_start_year, e.start_year) IS NOT NULL
        AND COALESCE(e.local_use_start_year, e.start_year) <= ?
        AND COALESCE(e.local_use_end_year, e.end_year, e.local_use_start_year, e.start_year) >= ?
    SQL

    rows.filter_map do |row|
      country = row["country"].to_s.presence
      next if context[:country].present? && country != context[:country]

      polities = parse_json_array(row["polities_json"])
      next if context[:polity].present? && !polities.any? { |value| value.include?(context[:polity]) || context[:polity].include?(value) }
      names = explicit_era_names(db, row["source"], row["era_id"])
      name = preferred_han_name(names, row["label"])
      next if name.blank?

      epoch = integer_or_nil(row["epoch_start_year"] || row["start_year"])
      epoch ||= adoption_epoch(db, row, name, year)
      next unless epoch

      era_year = era_year_number(epoch, year)
      next unless era_year&.positive?

      polity = polities.first
      expression = era_expression(name, era_year, year, row["era_id"].to_s)
      {
        "source" => row["source"].to_s,
        "source_display" => display_source(row["source"]),
        "id" => row["era_id"].to_s,
        "country" => country,
        "origin_country" => row["origin_country"].to_s.presence,
        "name_chn" => name,
        "label" => row["label"].to_s.presence || name,
        "local_label" => row["local_label"].to_s.presence,
        "polity" => polity,
        "polities" => polities,
        "epoch_start_year" => epoch,
        "use_start_year" => integer_or_nil(row["local_use_start_year"] || row["start_year"]),
        "use_end_year" => integer_or_nil(row["local_use_end_year"] || row["end_year"]),
        "year_number" => era_year,
        "year_number_han" => chinese_integer(era_year),
        "expression" => expression,
        "sexagenary" => sexagenary_for(year, taiping: row["era_id"].to_s == "china-taiping-tianguo-main"),
        "adopted_from_foreign" => row["adopted_from_foreign"].to_i == 1,
        "country_display" => display_country(country),
        "polity_display" => display_polity(polity, country: country),
        "polity_displays" => polities.map { |value| display_polity(value, country: country) }.compact.uniq,
        "rulers" => historical_rulers_for_era(db, row, year, name),
        "source_url" => row["source_url"].to_s.presence,
        "source_note" => row["source_note"].to_s.presence
      }.compact
    end
  end

  def cbdb_reverse_candidates(db, year, context)
    return [] unless table_exists?(db, "cbdb", "NIAN_HAO")

    columns = table_columns(db, "cbdb", "NIAN_HAO")
    id_column = choose_column(columns, %w[c_nianhao_id nianhao_id])
    name_column = choose_column(columns, %w[c_nianhao_chn nianhao_chn])
    pinyin_column = choose_column(columns, %w[c_nianhao_pin nianhao_pin])
    dynasty_column = choose_column(columns, %w[c_dynasty_chn dynasty_chn])
    dynasty_id_column = choose_column(columns, %w[c_dy dy])
    start_column = choose_column(columns, %w[c_firstyear firstyear])
    end_column = choose_column(columns, %w[c_lastyear lastyear])
    return [] unless id_column && name_column && start_column

    pinyin_sql = pinyin_column ? quote_identifier(pinyin_column) : "NULL"
    dynasty_sql = dynasty_column ? quote_identifier(dynasty_column) : "NULL"
    dynasty_id_sql = dynasty_id_column ? quote_identifier(dynasty_id_column) : "NULL"
    end_sql = end_column ? quote_identifier(end_column) : quote_identifier(start_column)
    sql = <<~SQL
      SELECT #{quote_identifier(id_column)} AS era_id,
             #{quote_identifier(name_column)} AS name_chn,
             #{pinyin_sql} AS nianhao_pin,
             #{dynasty_sql} AS dynasty_chn,
             #{dynasty_id_sql} AS dynasty_id,
             #{quote_identifier(start_column)} AS start_year,
             #{end_sql} AS end_year
      FROM cbdb.NIAN_HAO
      WHERE #{quote_identifier(start_column)} <= ?
        AND #{end_sql} >= ?
    SQL

    db.execute(sql, [year, year]).filter_map do |row|
      dynasty = row["dynasty_chn"].to_s.presence
      next if context[:polity].present? && dynasty.to_s.exclude?(context[:polity]) && context[:polity].exclude?(dynasty.to_s)
      next if context[:period].present? && dynasty.to_s.exclude?(context[:period]) && context[:period].exclude?(dynasty.to_s)

      epoch = integer_or_nil(row["start_year"])
      era_year = era_year_number(epoch, year)
      next unless era_year&.positive?

      name = row["name_chn"].to_s
      {
        "source" => "cbdb",
        "source_display" => display_source("cbdb"),
        "id" => row["era_id"].to_s,
        "country" => "China",
        "origin_country" => "China",
        "name_chn" => name,
        "label" => name,
        "polity" => dynasty,
        "polities" => [dynasty].compact,
        "epoch_start_year" => epoch,
        "use_start_year" => epoch,
        "use_end_year" => integer_or_nil(row["end_year"]),
        "year_number" => era_year,
        "year_number_han" => chinese_integer(era_year),
        "expression" => era_expression(name, era_year, year, nil),
        "adopted_from_foreign" => false,
        "country_display" => display_country("China"),
        "polity_display" => display_polity(dynasty, country: "China", english: cbdb_dynasty_english(db, row["dynasty_id"])),
        "polity_displays" => [display_polity(dynasty, country: "China", english: cbdb_dynasty_english(db, row["dynasty_id"]))].compact,
        "rulers" => cbdb_rulers_for_era(
          db,
          dynasty_id: row["dynasty_id"],
          year: year,
          era_start: epoch,
          era_end: integer_or_nil(row["end_year"]) || epoch
        ).presence || conventional_era_ruler(name, row["nianhao_pin"], dynasty),
        "source_url" => HistoricalAuthorityStore::CBDB_URL,
        "source_note" => HistoricalAuthorityStore::CBDB_CITATION
      }.compact
    end
  end

  def decorate_forward_candidates(candidates)
    return candidates unless @store.available?

    @store.with_database do |db|
      Array(candidates).map do |candidate|
        decorated = candidate.to_h.dup
        decorated["source_display"] = display_source(decorated["source"])
        country = decorated["country"].to_s.presence
        polities = Array(decorated["polities"]).map(&:to_s).reject(&:empty?)
        decorated["country_display"] = display_country(country)
        decorated["polity_displays"] = polities.map { |value| display_polity(value, country: country) }.compact.uniq
        decorated["polity_display"] = decorated["polity_displays"].first
        year = integer_or_nil(decorated["absolute_year"])

        if decorated["source"].to_s == "cbdb"
          decorated["rulers"] = cbdb_rulers_for_candidate(db, decorated, year)
          dynasty = Array(decorated["polities"]).first || decorated["dynasty"]
          decorated["polity_display"] ||= display_polity(dynasty, country: "China")
          decorated["polity_displays"] = [decorated["polity_display"]].compact if decorated["polity_displays"].blank?
        elsif @store.historical_available?
          row = db.get_first_row(
            "SELECT * FROM historical.eras WHERE source = ? AND era_id = ? LIMIT 1",
            [decorated["source"].to_s, decorated["id"].to_s]
          )
          if row
            decorated["rulers"] = historical_rulers_for_era(db, row, year, decorated["matched_name"] || decorated["label"])
            row_polities = parse_json_array(row["polities_json"])
            decorated["polity_displays"] = row_polities.map { |value| display_polity(value, country: country) }.compact.uniq if row_polities.any?
            decorated["polity_display"] = decorated["polity_displays"].first
          end
        end
        decorated.compact
      end
    end
  rescue StandardError
    candidates
  end

  def historical_rulers_for_era(db, era_row, year, era_name)
    source = era_row["source"].to_s
    era_id = era_row["era_id"].to_s
    related = db.execute(<<~SQL, [source, era_id])
      SELECT p.source, p.entity_id, p.label, p.local_label, p.romanized,
             p.year_start, p.year_end, p.source_url
      FROM historical.era_rulers er
      JOIN historical.people p
        ON p.source = er.ruler_source AND p.entity_id = er.ruler_id
      WHERE er.era_source = ? AND er.era_id = ?
      ORDER BY p.year_start, p.entity_id
    SQL

    if year
      active = related.select do |row|
        start_year = integer_or_nil(row["year_start"])
        end_year = integer_or_nil(row["year_end"]) || start_year
        start_year && end_year && year.between?(start_year, end_year)
      end
      related = active if active.any?
    end

    rulers = related.map { |row| historical_ruler_display(db, row) }
    if rulers.empty? && era_row["adopted_from_foreign"].to_i == 1
      rulers = origin_historical_rulers(db, era_row, year, era_name)
    end
    if rulers.empty? && source == "fanya_curated_era"
      rulers = curated_rulers(era_id, db)
    end
    rulers.compact.uniq { |row| [row["han_name"], row["english_label"], row["id"]] }
  end

  def origin_historical_rulers(db, era_row, year, era_name)
    origin = era_row["origin_country"].to_s.presence
    return [] unless origin && year && era_name.present?

    canonical = db.get_first_row(<<~SQL, [era_name, origin, year, year])
      SELECT e.*
      FROM historical.era_names n
      JOIN historical.eras e ON e.source = n.source AND e.era_id = n.era_id
      WHERE n.name_chn = ?
        AND e.country = ?
        AND COALESCE(e.start_year, e.epoch_start_year) <= ?
        AND COALESCE(e.end_year, e.start_year, e.epoch_start_year) >= ?
      ORDER BY n.explicit_name DESC, e.start_year DESC
      LIMIT 1
    SQL
    return [] unless canonical

    historical_rulers_for_era(db, canonical, year, era_name)
  end

  def historical_ruler_display(db, row)
    names = db.execute(<<~SQL, [row["source"].to_s, row["entity_id"].to_s])
      SELECT name_chn, primary_name, name_length
      FROM historical.names
      WHERE source = ? AND entity_id = ? AND explicit_name = 1
      ORDER BY primary_name DESC, name_length DESC, name_chn
    SQL
    han_names = names.map { |name_row| name_row["name_chn"].to_s }.reject(&:empty?).uniq.first(3)
    han_name = han_names.first || row["label"].to_s.presence
    english = latin_label(row["romanized"]) || latin_label(row["label"]) || latin_label(row["local_label"])
    {
      "source" => row["source"].to_s,
      "id" => row["entity_id"].to_s,
      "han_name" => han_name,
      "han_names" => han_names,
      "english_label" => english,
      "local_label" => row["local_label"].to_s.presence,
      "reign_start_year" => integer_or_nil(row["year_start"]),
      "reign_end_year" => integer_or_nil(row["year_end"]),
      "source_url" => row["source_url"].to_s.presence,
      "confidence" => "authority_relation"
    }.compact
  end

  def curated_rulers(era_id, db)
    record = curated_era_records.find { |row| row["id"].to_s == era_id.to_s }
    names = compact_equivalent_names(Array(record&.dig("ruler_names")))
    names.map do |name|
      english = cbdb_person_english(db, name)
      {
        "source" => "fanya_curated_era",
        "han_name" => name,
        "han_names" => [name],
        "english_label" => english,
        "confidence" => "curated"
      }.compact
    end
  end

  def curated_era_records
    return @curated_era_records if defined?(@curated_era_records)

    path = HistoricalAuthorityIndex::CURATED_ERA_SOURCE_PATH
    payload = JSON.parse(path.read(encoding: "bom|utf-8"))
    @curated_era_records = Array(payload["eras"])
  rescue StandardError
    @curated_era_records = []
  end

  def compact_equivalent_names(names)
    expander = AuthorityNameExpander.new
    kept = []
    Array(names).map(&:to_s).map(&:strip).reject(&:empty?).each do |name|
      next if kept.any? { |existing| expander.expand(existing).any? { |form| form.name == name } }
      kept << name
    end
    kept
  rescue StandardError
    Array(names).map(&:to_s).map(&:strip).reject(&:empty?).uniq
  end

  def cbdb_person_english(db, han_name)
    return nil unless @store.cbdb_available? && table_exists?(db, "cbdb", "BIOG_MAIN")

    db.get_first_value(
      "SELECT c_name FROM cbdb.BIOG_MAIN WHERE c_name_chn = ? AND c_name IS NOT NULL AND c_name <> '' ORDER BY c_personid LIMIT 1",
      [han_name]
    ).to_s.presence
  rescue StandardError
    nil
  end

  def cbdb_dynasty_english(db, dynasty_id)
    return nil unless dynasty_id && table_exists?(db, "cbdb", "DYNASTIES")

    db.get_first_value("SELECT c_dynasty FROM cbdb.DYNASTIES WHERE c_dy = ? LIMIT 1", [dynasty_id]).to_s.presence
  rescue StandardError
    nil
  end

  def cbdb_rulers_for_candidate(db, candidate, year)
    return [] unless year
    era_id = candidate["id"].to_s
    return [] unless table_exists?(db, "cbdb", "NIAN_HAO")

    row = db.get_first_row(
      "SELECT c_dy, c_dynasty_chn, c_nianhao_chn, c_nianhao_pin, c_firstyear, c_lastyear FROM cbdb.NIAN_HAO WHERE c_nianhao_id = ? LIMIT 1",
      [era_id]
    )
    return [] unless row

    rulers = cbdb_rulers_for_era(
      db,
      dynasty_id: row["c_dy"],
      year: year,
      era_start: integer_or_nil(row["c_firstyear"]),
      era_end: cbdb_nonzero_year(row["c_lastyear"]) || cbdb_nonzero_year(row["c_firstyear"])
    )
    rulers.presence || conventional_era_ruler(row["c_nianhao_chn"], row["c_nianhao_pin"], row["c_dynasty_chn"])
  rescue StandardError
    []
  end

  def cbdb_rulers_for_era(db, dynasty_id:, year:, era_start:, era_end:)
    return [] unless dynasty_id && year
    return [] unless table_exists?(db, "cbdb", "STATUS_DATA") && table_exists?(db, "cbdb", "BIOG_MAIN")

    explicit = db.execute(<<~SQL, [dynasty_id, year, year])
      SELECT b.c_personid, b.c_name_chn, b.c_name, b.c_birthyear, b.c_deathyear,
             s.c_firstyear, s.c_lastyear
      FROM cbdb.STATUS_DATA s
      JOIN cbdb.BIOG_MAIN b ON b.c_personid = s.c_personid
      WHERE s.c_status_code = 26
        AND b.c_dy = ?
        AND s.c_firstyear IS NOT NULL AND s.c_firstyear <> 0
        AND s.c_lastyear IS NOT NULL AND s.c_lastyear <> 0
        AND s.c_firstyear <= ? AND s.c_lastyear >= ?
      ORDER BY s.c_firstyear, b.c_personid
    SQL
    return explicit.map { |row| cbdb_ruler_display(db, row, confidence: "cbdb_reign_range") } if explicit.any?

    # Some CBDB emperor-status rows identify the ruler but leave the reign dates
    # as zero. Only infer from succession/death boundaries when the entire era
    # interval lies strictly inside one candidate's interval; succession years
    # themselves remain deliberately unresolved at year granularity.
    emperors = db.execute(<<~SQL, [dynasty_id])
      SELECT DISTINCT b.c_personid, b.c_name_chn, b.c_name, b.c_birthyear, b.c_deathyear
      FROM cbdb.STATUS_DATA s
      JOIN cbdb.BIOG_MAIN b ON b.c_personid = s.c_personid
      WHERE s.c_status_code = 26
        AND b.c_dy = ?
        AND b.c_deathyear IS NOT NULL AND b.c_deathyear <> 0
      ORDER BY b.c_deathyear, b.c_personid
    SQL
    return [] if emperors.empty?

    left = era_start || year
    right = era_end || year
    candidate_index = emperors.index do |row|
      death = integer_or_nil(row["c_deathyear"])
      birth = integer_or_nil(row["c_birthyear"])
      death && death > right && (!birth || birth <= left)
    end
    return [] unless candidate_index

    candidate = emperors[candidate_index]
    previous_death = emperors[0...candidate_index].filter_map { |row| integer_or_nil(row["c_deathyear"]) }.max
    if previous_death.nil? && table_exists?(db, "cbdb", "DYNASTIES")
      dynasty_start = integer_or_nil(db.get_first_value("SELECT c_start FROM cbdb.DYNASTIES WHERE c_dy = ? LIMIT 1", [dynasty_id]))
      previous_death = dynasty_start ? dynasty_start - 1 : nil
    end
    return [] unless previous_death && left > previous_death && right < integer_or_nil(candidate["c_deathyear"])

    [cbdb_ruler_display(db, candidate, confidence: "inferred_from_cbdb_succession")]
  rescue StandardError
    []
  end

  def cbdb_ruler_display(db, row, confidence:)
    person_id = row["c_personid"]
    title_row = if table_exists?(db, "cbdb", "ALTNAME_DATA")
      db.get_first_row(<<~SQL, [person_id])
        SELECT c_alt_name_chn, c_alt_name
        FROM cbdb.ALTNAME_DATA
        WHERE c_personid = ?
          AND c_alt_name_chn LIKE '%帝%'
        ORDER BY CASE WHEN length(c_alt_name_chn) <= 4 THEN 0 ELSE 1 END,
                 CASE c_alt_name_type_code WHEN 14 THEN 0 WHEN 6 THEN 1 ELSE 2 END,
                 length(c_alt_name_chn), c_sequence
        LIMIT 1
      SQL
    end
    han_name = title_row&.fetch("c_alt_name_chn", nil).to_s.presence || row["c_name_chn"].to_s.presence
    english = title_row&.fetch("c_alt_name", nil).to_s.presence || row["c_name"].to_s.presence
    personal = row["c_name_chn"].to_s.presence
    {
      "source" => "cbdb",
      "id" => person_id.to_s,
      "han_name" => han_name,
      "han_names" => [han_name, personal].compact.uniq,
      "english_label" => english,
      "reign_start_year" => integer_or_nil(row["c_firstyear"]),
      "reign_end_year" => integer_or_nil(row["c_lastyear"]),
      "source_url" => HistoricalAuthorityStore::CBDB_URL,
      "confidence" => confidence
    }.compact
  end

  def conventional_era_ruler(name, reading, dynasty)
    return [] unless %w[明 清].include?(dynasty.to_s)
    return [] unless name.to_s.match?(/\A\p{Han}{2,6}\z/)

    english = reading.to_s.strip.presence
    english = "#{english} Emperor" if english && !english.match?(/emperor/i)
    [{
      "source" => "cbdb",
      "han_name" => "#{name}帝",
      "han_names" => ["#{name}帝"],
      "english_label" => english,
      "source_url" => HistoricalAuthorityStore::CBDB_URL,
      "confidence" => "conventional_era_title"
    }.compact]
  end

  def display_source(source)
    key = source.to_s
    SOURCE_DISPLAY[key] || key.tr("_", " ").presence
  end

  def display_country(country)
    pair = COUNTRY_DISPLAY[country.to_s]
    pair ? display_pair(*pair) : country.to_s.presence
  end

  def display_polity(value, country:, english: nil)
    raw = value.to_s.strip
    return nil if raw.empty?

    pair = POLITY_DISPLAY[raw]
    return display_pair(*pair) if pair

    if raw.match?(/\p{Han}/)
      display_pair(raw, english)
    else
      display_pair(nil, raw)
    end
  end

  def display_pair(han, english)
    han = han.to_s.strip.presence
    english = english.to_s.strip.presence
    return english unless han
    return han unless english && english != han

    "#{han} (#{english})"
  end

  def latin_label(value)
    text = value.to_s.strip
    return nil if text.empty? || text.match?(/\p{Han}/)

    text
  end

  def adoption_epoch(db, row, name, year)
    origin = row["origin_country"].to_s.presence
    return nil unless row["adopted_from_foreign"].to_i == 1 && origin

    historical = db.get_first_row(<<~SQL, [name, origin, year, year])
      SELECT e.epoch_start_year, e.start_year
      FROM historical.era_names n
      JOIN historical.eras e ON e.source = n.source AND e.era_id = n.era_id
      WHERE n.name_chn = ?
        AND e.country = ?
        AND COALESCE(e.epoch_start_year, e.start_year) IS NOT NULL
        AND (e.start_year IS NULL OR e.start_year <= ?)
        AND (e.end_year IS NULL OR e.end_year >= ?)
      ORDER BY n.explicit_name DESC, e.start_year DESC
      LIMIT 1
    SQL
    epoch = integer_or_nil(historical&.fetch("epoch_start_year", nil) || historical&.fetch("start_year", nil))
    return epoch if epoch

    return nil unless origin == "China" && @store.cbdb_available? && table_exists?(db, "cbdb", "NIAN_HAO")

    columns = table_columns(db, "cbdb", "NIAN_HAO")
    name_column = choose_column(columns, %w[c_nianhao_chn nianhao_chn])
    start_column = choose_column(columns, %w[c_firstyear firstyear])
    end_column = choose_column(columns, %w[c_lastyear lastyear])
    return nil unless name_column && start_column

    end_sql = end_column ? quote_identifier(end_column) : quote_identifier(start_column)
    value = db.get_first_value(<<~SQL, [name, year, year])
      SELECT #{quote_identifier(start_column)}
      FROM cbdb.NIAN_HAO
      WHERE #{quote_identifier(name_column)} = ?
        AND #{quote_identifier(start_column)} <= ?
        AND #{end_sql} >= ?
      ORDER BY #{quote_identifier(start_column)} DESC
      LIMIT 1
    SQL
    integer_or_nil(value)
  end

  def explicit_era_names(db, source, era_id)
    db.execute(
      "SELECT name_chn FROM historical.era_names WHERE source = ? AND era_id = ? AND explicit_name = 1 ORDER BY name_length DESC, name_chn",
      [source, era_id]
    ).map { |row| row["name_chn"].to_s }.reject(&:empty?).uniq
  end

  def preferred_han_name(names, fallback)
    canonical = fallback.to_s
    return canonical if canonical.match?(/\p{Han}/)

    Array(names).find { |value| value.match?(/\p{Han}/) } || canonical
  end

  def era_expression(name, year_number, absolute_year, era_id)
    numeral = year_number == 1 ? "元" : chinese_integer(year_number)
    prefix = name.to_s
    if era_id.to_s == "china-taiping-tianguo-main"
      prefix += sexagenary_for(absolute_year, taiping: true).to_s
    end
    "#{prefix}#{numeral}年"
  end

  def sexagenary_for(year, taiping: false)
    return nil unless year.to_i.positive?

    index = (year.to_i - 4) % 60
    stem = STEMS[index % 10]
    branch = BRANCHES[index % 12]
    branch = TAIPING_BRANCHES.fetch(branch, branch) if taiping
    "#{stem}#{branch}"
  end

  def era_year_number(epoch, absolute_year)
    return nil unless epoch && absolute_year
    return nil if absolute_year.zero?

    if epoch.negative? && absolute_year.positive?
      absolute_year - epoch
    else
      absolute_year - epoch + 1
    end
  end

  def chinese_integer(value)
    number = Integer(value)
    return "零" if number.zero?
    return number.to_s if number.negative? || number > 9_999

    digits = %w[零 一 二 三 四 五 六 七 八 九]
    units = [[1000, "千"], [100, "百"], [10, "十"]]
    remainder = number
    output = +""
    zero_pending = false

    units.each do |unit, glyph|
      digit = remainder / unit
      remainder %= unit
      if digit.positive?
        output << "零" if zero_pending && !output.empty?
        output << digits[digit] << glyph
        zero_pending = false
      elsif !output.empty? && remainder.positive?
        zero_pending = true
      end
    end

    if remainder.positive?
      output << "零" if zero_pending && !output.empty?
      output << digits[remainder]
    end

    output = output.sub(/\A一十/, "十")
    output
  end

  def normalized_context(country:, polity:, period:)
    chosen_country = country.to_s.strip
    chosen_country = nil unless COUNTRIES.include?(chosen_country)
    {
      country: chosen_country,
      polity: polity.to_s.strip.presence,
      period: period.to_s.strip.presence
    }
  end

  def context_metadata(context)
    {
      "nation" => context[:country],
      "corpus_root" => context[:country],
      "polity" => context[:polity],
      "period" => context[:period]
    }.compact
  end

  def country_sort(row, context)
    return 0 unless context[:country].present?

    row["country"].to_s == context[:country] ? 0 : 1
  end

  def polity_sort(row, context)
    return 0 unless context[:polity].present?

    Array(row["polities"]).any? { |value| value.include?(context[:polity]) || context[:polity].include?(value) } ? 0 : 1
  end

  def parse_json_array(value)
    parsed = JSON.parse(value.to_s)
    parsed.is_a?(Array) ? parsed.map(&:to_s) : []
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
    candidates.each { |candidate| return lookup[candidate.downcase] if lookup.key?(candidate.downcase) }
    nil
  end

  def quote_identifier(value)
    %Q{"#{value.to_s.gsub('"', '""')}"}
  end

  def cbdb_nonzero_year(value)
    year = integer_or_nil(value)
    year unless year == 0
  end

  def integer_or_nil(value)
    Integer(value) if value.to_s.match?(/\A-?\d+\z/)
  rescue ArgumentError, TypeError
    nil
  end

  def year_label(year)
    year.to_i.negative? ? "#{year.to_i.abs} BCE" : "#{year.to_i} CE"
  end
end
