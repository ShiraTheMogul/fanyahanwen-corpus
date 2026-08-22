# frozen_string_literal: true

require "set"

# Unified automatic named-entity annotator. The historical class name is kept
# for compatibility with earlier CBDB-only callers, while candidate data can
# now come from CBDB, the Shang/Xia workbook, and the East Asian ruler index.
class CbdbAutoAnnotator
  PREFIX_BATCH_SIZE = 350
  KIND_PRIORITY = { "person" => 3, "place" => 2, "office" => 1 }.freeze
  SOURCE_PRIORITY = {
    "fanya_supplementary" => 4,
    "wikidata_east_asia" => 3,
    "wikidata_east_asia+wikipedia_ruler_list" => 3,
    "wikipedia_ruler_list" => 2,
    "cbdb" => 1
  }.freeze

  Result = Data.define(:items, :context, :authority)

  def self.call(text:, metadata:, store: HistoricalAuthorityStore.default)
    new(text: text, metadata: metadata, store: store).call
  end

  def initialize(text:, metadata:, store:)
    @text = text.to_s
    @chars = @text.each_char.to_a
    @metadata = metadata.to_h.stringify_keys
    @store = normalize_store(store)
    @equivalence = CorpusSearch::CharacterEquivalenceRegistry.new(level: "broad")
    @prefix_cache = {}
  end

  def call
    return Result.new(items: [], context: temporal_context, authority: @store.metadata) unless @store.available?

    @context = temporal_context
    matches = []
    @store.with_database do |db|
      @db = db
      prefixes = text_prefixes
      matches.concat(cbdb_matches(prefixes)) if @store.lookup_available? && prefixes.any?
      matches.concat(historical_matches(prefixes)) if @store.historical_available? && prefixes.any?
      matches.concat(single_character_diviner_matches) if @store.historical_available?
    ensure
      @db = nil
    end

    Result.new(items: resolve_overlaps(matches).map { |match| public_item(match) }, context: @context, authority: @store.metadata)
  rescue StandardError => e
    Rails.logger&.warn("[authority] automatic annotation unavailable: #{e.class}: #{e.message}") if defined?(Rails)
    Result.new(items: [], context: temporal_context, authority: @store.metadata)
  end

  private

  def normalize_store(store)
    return store if store.respond_to?(:historical_available?)

    HistoricalAuthorityStore.new(
      cbdb_path: store.respond_to?(:source_path) ? store.source_path : nil,
      cbdb_release: store.respond_to?(:release) ? store.release : {},
      lookup_path: store.respond_to?(:lookup_path) ? store.lookup_path : nil,
      historical_path: nil,
      cache_store: store.respond_to?(:cache_store) ? store.cache_store : CorpusSearch::CacheStore.new,
      logger: nil
    )
  end

  def cbdb_matches(prefixes)
    rows = fetch_pointer_rows("cbdb_lookup", prefixes)
    hydrated = hydrate_cbdb(rows)
    build_multi_matches(hydrated)
  end

  def historical_matches(prefixes)
    rows = []
    expanded_prefixes(prefixes).each_slice(PREFIX_BATCH_SIZE) do |slice|
      placeholders = (["?"] * slice.length).join(",")
      rows.concat(@db.execute(<<~SQL, slice))
        SELECT n.name_chn, n.name_length, n.source, n.entity_id,
               n.primary_name, n.explicit_name, n.derivation,
               p.country, p.label, p.local_label, p.romanized,
               p.year_start, p.year_end, p.date_label, p.polity,
               p.roles, p.places, p.source_url, p.source_citations,
               p.chronology_confidence, p.external_ids, p.shang_diviner
        FROM historical.names n
        JOIN historical.people p
          ON p.source = n.source AND p.entity_id = n.entity_id
        WHERE n.prefix IN (#{placeholders}) AND n.name_length >= 2
      SQL
    end

    rows.map do |row|
      candidate = historical_candidate(row)
      next unless candidate
      row.to_h.merge("candidate" => candidate)
    end.compact.then { |values| build_multi_matches(values) }
  end

  def fetch_pointer_rows(schema, prefixes)
    rows = []
    expanded_prefixes(prefixes).each_slice(PREFIX_BATCH_SIZE) do |slice|
      placeholders = (["?"] * slice.length).join(",")
      rows.concat(@db.execute(<<~SQL, slice))
        SELECT prefix, name_length, name_chn, kind, entity_id, primary_name
        FROM #{schema}.names
        WHERE prefix IN (#{placeholders}) AND name_length >= 2
      SQL
    end
    rows
  end

  def hydrate_cbdb(rows)
    by_kind = rows.group_by { |row| row["kind"].to_s }
    details = {}
    by_kind.each do |kind, kind_rows|
      ids = kind_rows.map { |row| row["entity_id"].to_s }.uniq
      details[kind] = cbdb_details(kind, ids)
    end

    rows.filter_map do |row|
      kind = row["kind"].to_s
      detail = details.fetch(kind, {})[row["entity_id"].to_s] || {}
      candidate = cbdb_candidate(row, detail)
      next unless candidate
      row.to_h.merge("candidate" => candidate)
    end
  end

  def cbdb_details(kind, ids)
    return {} if ids.empty?

    table, id_candidates = case kind
    when "person" then ["BIOG_MAIN", %w[c_personid person_id]]
    when "place" then ["ADDR_CODES", %w[c_addr_id c_addrid addr_id]]
    when "office" then ["OFFICE_CODES", %w[c_office_id c_officeid office_id]]
    else return {}
    end
    return {} unless table_exists?("cbdb", table)

    columns = table_columns("cbdb", table)
    id_column = choose_column(columns, id_candidates)
    return {} unless id_column

    output = {}
    ids.each_slice(400) do |slice|
      placeholders = (["?"] * slice.length).join(",")
      @db.execute("SELECT * FROM cbdb.#{quote_identifier(table)} WHERE #{quote_identifier(id_column)} IN (#{placeholders})", slice).each do |row|
        output[row[id_column].to_s] = row.to_h
      end
    end
    output
  end

  def cbdb_candidate(pointer, detail)
    kind = pointer["kind"].to_s
    columns = detail.keys.map(&:to_s)
    label_column = choose_column(columns, case kind
      when "person" then %w[c_name_chn c_name_ch name_chn]
      when "place" then %w[c_name_chn c_addr_chn c_addr_name_chn name_chn]
      when "office" then %w[c_office_chn c_name_chn c_office_name_chn office_chn]
      else []
    end)
    start_year, end_year = cbdb_years(kind, detail)
    score = contextual_score(start_year, end_year, country: kind == "person" ? "China" : nil, explicit: true)

    {
      id: pointer["entity_id"].to_s,
      label: label_column ? detail[label_column].to_s.presence : pointer["name_chn"].to_s,
      kind: kind,
      year_start: start_year,
      year_end: end_year,
      primary: pointer["primary_name"].to_i == 1,
      explicit: true,
      derivation: "cbdb_explicit",
      authority_source: "cbdb",
      source_label: "China Biographical Database",
      source_url: HistoricalAuthorityStore::CBDB_URL,
      score: score
    }.compact
  end

  def cbdb_years(kind, detail)
    case kind
    when "person"
      start_year = first_integer(detail, %w[c_birthyear c_fl_earliest_year c_index_year c_firstyear])
      end_year = first_integer(detail, %w[c_deathyear c_fl_latest_year c_index_year c_lastyear])
      [start_year, end_year]
    when "place"
      [first_integer(detail, %w[c_firstyear firstyear]), first_integer(detail, %w[c_lastyear lastyear])]
    else
      [nil, nil]
    end
  end

  def historical_candidate(row)
    explicit = row["explicit_name"].to_i == 1
    start_year = integer_or_nil(row["year_start"])
    end_year = integer_or_nil(row["year_end"])
    score = contextual_score(start_year, end_year, country: row["country"], explicit: explicit)

    {
      id: row["entity_id"].to_s,
      label: row["label"].to_s.presence || row["name_chn"].to_s,
      local_label: row["local_label"].to_s.presence,
      romanized: row["romanized"].to_s.presence,
      kind: "person",
      country: row["country"].to_s.presence,
      year_start: start_year,
      year_end: end_year,
      date_label: row["date_label"].to_s.presence,
      polity: row["polity"].to_s.presence,
      roles: row["roles"].to_s.presence,
      places: row["places"].to_s.presence,
      primary: row["primary_name"].to_i == 1,
      explicit: explicit,
      derivation: row["derivation"].to_s,
      authority_source: row["source"].to_s,
      source_label: source_label(row["source"]),
      source_url: row["source_url"].to_s.presence,
      source_reference: first_source_reference(row["source_citations"]),
      chronology_confidence: row["chronology_confidence"].to_s.presence,
      external_ids: row["external_ids"].to_s.presence,
      shang_diviner: row["shang_diviner"].to_i == 1,
      score: score
    }.compact
  end

  def build_multi_matches(rows)
    by_prefix = Hash.new { |hash, key| hash[key] = Hash.new { |inner, name| inner[name] = [] } }
    rows.each do |row|
      name = row["name_chn"].to_s
      candidate = row["candidate"]
      next if name.each_char.count < 2 || !candidate

      prefix = name.each_char.take(2).join
      by_prefix[prefix][name] << candidate
    end
    by_prefix.each_value do |names|
      names.each_value do |candidates|
        candidates.uniq! { |candidate| [candidate[:authority_source], candidate[:id], candidate[:derivation]] }
        candidates.sort_by! { |candidate| candidate_sort_key(candidate) }
      end
    end

    matches = []
    i = 0
    while i < @chars.length - 1
      literal_prefix = @chars[i, 2].join
      unless @chars[i].to_s.match?(/\p{Han}/) && @chars[i + 1].to_s.match?(/\p{Han}/)
        i += 1
        next
      end

      names = equivalent_prefixes(literal_prefix).flat_map { |prefix| by_prefix[prefix].to_a }
        .group_by(&:first).transform_values { |pairs| pairs.flat_map(&:last) }
      if names.empty?
        i += 1
        next
      end

      matched_name = names.keys.sort_by { |name| -name.each_char.count }.find { |name| name_matches_at?(name, i) }
      unless matched_name
        i += 1
        next
      end

      candidates = names.fetch(matched_name).uniq { |candidate| [candidate[:authority_source], candidate[:id], candidate[:derivation]] }
        .sort_by { |candidate| candidate_sort_key(candidate) }
      top_score = candidates.first.fetch(:score)
      top = candidates.select { |candidate| candidate.fetch(:score) == top_score }
      confidence = confidence_for(top, top_score)
      length = matched_name.each_char.count
      matches << {
        start: i,
        end: i + length,
        text: @chars[i, length].join,
        kind: candidates.first.fetch(:kind, "person"),
        confidence: confidence,
        score: top_score,
        candidates: candidates.first(8)
      }
      i += length
    end
    matches
  end

  def single_character_diviner_matches
    return [] unless shang_diviner_visible_in_context?

    positions = one_character_diviner_positions
    return [] if positions.empty?

    chars = positions.keys
    placeholders = (["?"] * chars.length).join(",")
    rows = @db.execute(<<~SQL, chars)
      SELECT n.name_chn, n.source, n.entity_id, n.primary_name,
             n.explicit_name, n.derivation,
             p.country, p.label, p.local_label, p.romanized,
             p.year_start, p.year_end, p.date_label, p.polity,
             p.roles, p.places, p.source_url, p.source_citations,
             p.chronology_confidence, p.external_ids, p.shang_diviner
      FROM historical.names n
      JOIN historical.people p ON p.source = n.source AND p.entity_id = n.entity_id
      WHERE n.name_length = 1 AND n.name_chn IN (#{placeholders}) AND p.shang_diviner = 1
    SQL

    by_char = Hash.new { |hash, key| hash[key] = [] }
    rows.each do |row|
      candidate = historical_candidate(row)
      by_char[row["name_chn"].to_s] << candidate if candidate
    end

    matches = []
    positions.each do |literal, indexes|
      candidate_rows = equivalent_forms(literal).flat_map { |form| by_char[form] }
        .uniq { |candidate| [candidate[:authority_source], candidate[:id], candidate[:derivation]] }
        .sort_by { |candidate| candidate_sort_key(candidate) }
      next if candidate_rows.empty?

      top_score = candidate_rows.first.fetch(:score)
      top = candidate_rows.select { |candidate| candidate.fetch(:score) == top_score }
      confidence = confidence_for(top, top_score)
      indexes.each do |index|
        matches << {
          start: index, end: index + 1, text: literal, kind: "person",
          confidence: confidence, score: top_score, candidates: candidate_rows.first(8)
        }
      end
    end
    matches
  end

  def contextual_score(start_year, end_year, country:, explicit:)
    score = explicit ? 82 : 76
    context_start = @context && @context["year_start"]
    context_end = @context && @context["year_end"]
    if (context_start || context_end) && (start_year || end_year)
      left = context_start || context_end
      right = context_end || context_start
      candidate_start = start_year || end_year
      candidate_end = end_year || start_year
      if candidate_end >= left && candidate_start <= right
        score += 22
      else
        # Later authors cite earlier people constantly. Chronology ranks person
        # candidates; it does not erase historically possible references.
        score -= 10
      end
    end

    context_country = @context && @context["country"]
    if context_country.present? && country.present?
      score += 8 if context_country == country
      score -= 3 if context_country != country
    end
    score
  end

  def temporal_context
    resolution = HistoricalDateResolver.resolve(metadata: @metadata, store: @store)
    country = context_country(@metadata)
    {
      "year_start" => resolution&.year_start || integer_or_nil(@metadata["year_start"] || @metadata["year"]),
      "year_end" => resolution&.year_end || integer_or_nil(@metadata["year_end"] || @metadata["year"]),
      "country" => country,
      "period" => @metadata["period"].to_s.presence,
      "polity" => @metadata["polity"].to_s.presence,
      "date_resolution" => resolution&.to_h
    }.compact
  end

  def context_country(metadata)
    text = [metadata["corpus_root"], metadata["nation"], metadata["period"], metadata["polity"], metadata["region"]].map(&:to_s).join(" ")
    HistoricalDateResolver::COUNTRY_HINTS.each do |hint, country|
      return country if text.include?(hint)
    end
    nil
  end

  def text_prefixes
    output = Set.new
    @chars.each_cons(2) do |left, right|
      next unless left.to_s.match?(/\p{Han}/) && right.to_s.match?(/\p{Han}/)
      output << left + right
    end
    output.to_a
  end

  def expanded_prefixes(prefixes)
    prefixes.flat_map { |prefix| equivalent_prefixes(prefix) }.uniq
  end

  def equivalent_prefixes(prefix)
    @prefix_cache[prefix] ||= begin
      chars = prefix.each_char.to_a
      return [prefix] unless chars.length == 2
      left = equivalent_forms(chars[0]).first(12)
      right = equivalent_forms(chars[1]).first(12)
      left.product(right).map(&:join).uniq.first(96)
    end
  end

  def equivalent_forms(character)
    @equivalence.forms_for(character).to_a.sort
  rescue StandardError
    [character]
  end

  def name_matches_at?(authority_name, index)
    authority_name.each_char.with_index.all? do |character, offset|
      source = @chars[index + offset]
      source && @equivalence.equivalent?(character, source)
    end
  end

  def resolve_overlaps(matches)
    exact = matches.group_by { |match| [match[:start], match[:end], match[:kind]] }.values.map do |group|
      best = group.max_by { |match| [match[:score], KIND_PRIORITY.fetch(match[:kind], 0)] }
      candidates = group.flat_map { |match| match[:candidates] }
        .uniq { |candidate| [candidate[:authority_source], candidate[:id], candidate[:derivation]] }
        .sort_by { |candidate| candidate_sort_key(candidate) }
      top_score = candidates.first&.fetch(:score, best[:score]) || best[:score]
      best.merge(
        score: top_score,
        confidence: confidence_for(candidates.select { |candidate| candidate[:score] == top_score }, top_score),
        candidates: candidates.first(8)
      )
    end

    selected = []
    exact.sort_by { |match| [match[:start], -(match[:end] - match[:start]), -match[:score], -KIND_PRIORITY.fetch(match[:kind], 0)] }.each do |match|
      next if selected.any? { |other| ranges_overlap?(match, other) }
      selected << match
    end
    selected.sort_by { |match| [match[:start], match[:end]] }
  end

  def public_item(match)
    {
      "start" => match.fetch(:start),
      "end" => match.fetch(:end),
      "kind" => match.fetch(:kind),
      "text" => match.fetch(:text),
      "confidence" => match.fetch(:confidence),
      "authority_source" => authority_source_label(match.fetch(:candidates)),
      "candidates" => match.fetch(:candidates).map do |candidate|
        candidate.except(:score).stringify_keys
      end
    }
  end

  def confidence_for(candidates, score)
    ids = candidates.map { |candidate| [candidate[:authority_source], candidate[:id]] }.uniq
    explicit = candidates.any? { |candidate| candidate.fetch(:explicit, true) }
    ids.length == 1 && score >= (explicit ? 90 : 94) ? "high" : "possible"
  end

  def candidate_sort_key(candidate)
    [
      -candidate.fetch(:score),
      candidate[:primary] ? 0 : 1,
      candidate.fetch(:explicit, true) ? 0 : 1,
      -SOURCE_PRIORITY.fetch(candidate[:authority_source].to_s, 0),
      candidate[:id].to_s
    ]
  end

  def authority_source_label(candidates)
    sources = candidates.map { |candidate| candidate[:authority_source] }.compact.uniq
    sources.length == 1 ? sources.first : "multiple"
  end

  def source_label(source)
    case source.to_s
    when "fanya_supplementary" then "Fanya supplementary authority"
    when "wikidata_east_asia" then "Wikidata East Asian ruler authority"
    when "wikidata_east_asia+wikipedia_ruler_list" then "Wikidata + Wikipedia ruler authority"
    when "wikipedia_ruler_list" then "Wikipedia ruler-list authority"
    else source.to_s
    end
  end

  def first_source_reference(value)
    value.to_s.lines.map(&:strip).reject(&:empty?).first.to_s[0, 500].presence
  end

  def one_character_diviner_positions
    positions = Hash.new { |hash, key| hash[key] = [] }
    @chars.each_index do |index|
      character = @chars[index]
      next unless character.to_s.match?(/\p{Han}/)
      next unless one_character_diviner_syntax?(index)
      positions[character] << index
    end
    positions
  end

  def one_character_diviner_syntax?(index)
    cursor = index + 1
    punctuation_between = false
    while cursor < @chars.length && @chars[cursor].to_s.match?(/[\s，,、；;：:。．·・]/)
      punctuation_between = true unless @chars[cursor].to_s.match?(/\s/)
      cursor += 1
    end
    return false unless %w[貞 贞].include?(@chars[cursor])

    divination_clause_before(index).include?("卜") || punctuation_between
  end

  def divination_clause_before(index, limit: 24)
    collected = []
    cursor = index - 1
    while cursor >= 0 && collected.length < limit
      character = @chars[cursor]
      break if character.to_s.match?(/[。！？!?；;\n\r]/)
      collected.unshift(character)
      cursor -= 1
    end
    collected.join
  end

  def shang_diviner_visible_in_context?
    period = @context.to_h["period"].to_s
    return true if period.include?("商") || period == "Late Shang"
    return true if period.match?(/中華民國|民國|中華人民共和國|現代|近現代/)

    start_year = @context.to_h["year_start"]
    end_year = @context.to_h["year_end"]
    return true if start_year && start_year >= 1912
    return false unless period.empty?

    start_year && end_year && start_year <= -1046 && end_year > -1600
  end

  def ranges_overlap?(left, right)
    left[:start] < right[:end] && right[:start] < left[:end]
  end

  def table_exists?(schema, table)
    @db.get_first_value("SELECT 1 FROM #{schema}.sqlite_master WHERE type='table' AND name = ? LIMIT 1", [table]).to_i == 1
  end

  def table_columns(schema, table)
    @db.execute("PRAGMA #{schema}.table_info(#{quote_identifier(table)})").map { |row| row["name"].to_s }
  end

  def choose_column(columns, candidates)
    lookup = columns.to_h { |column| [column.downcase, column] }
    candidates.each { |candidate| return lookup[candidate.downcase] if lookup.key?(candidate.downcase) }
    nil
  end

  def quote_identifier(value)
    %Q{"#{value.to_s.gsub('"', '""')}"}
  end

  def first_integer(row, candidates)
    columns = row.keys.map(&:to_s)
    candidates.each do |candidate|
      actual = columns.find { |column| column.casecmp(candidate).zero? }
      value = actual && integer_or_nil(row[actual])
      return value if value
    end
    nil
  end

  def integer_or_nil(value)
    Integer(value) if value.to_s.match?(/\A-?\d+\z/)
  rescue ArgumentError, TypeError
    nil
  end
end
