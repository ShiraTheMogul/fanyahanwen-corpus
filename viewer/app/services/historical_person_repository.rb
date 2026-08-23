# frozen_string_literal: true

require "json"

# Read-only person/author facade over CBDB and the supplementary historical
# authority index. Identity suggestions remain suggestions: callers receive the
# candidates and provenance needed to let a reader choose among them.
class HistoricalPersonRepository
  CBDB_APA_CITATION = "Harvard University, Academia Sinica, & Peking University. (2025, May). China Biographical Database (CBDB) [Database]. https://projects.iq.harvard.edu/cbdb".freeze

  CandidateSet = Data.define(:query_names, :candidates, :authority)

  def initialize(store: HistoricalAuthorityStore.default)
    @store = store
  end

  def find_candidates(names:, metadata: {})
    queries = Array(names).flat_map { |value| han_name_fragments(value) }.uniq
    return CandidateSet.new(query_names: [], candidates: [], authority: authority_metadata) if queries.empty?

    candidates = []
    @store.with_database do |db|
      queries.each do |query|
        equivalent_names = authority_name_forms(query)
        candidates.concat(cbdb_person_candidates(db, query, equivalent_names)) if @store.cbdb_available?
        candidates.concat(historical_person_candidates(db, query, equivalent_names)) if @store.historical_available?
      end
    end if @store.available?

    candidates = candidates
      .uniq { |candidate| [candidate["authority_source"], candidate["id"]] }
      .sort_by { |candidate| [candidate["confidence"] == "high" ? 0 : 1, candidate["authority_source"].to_s, candidate["id"].to_s] }

    CandidateSet.new(
      query_names: queries,
      candidates: candidates,
      authority: authority_metadata
    )
  rescue StandardError => e
    Rails.logger&.warn("[authority] person lookup failed: #{e.class}: #{e.message}") if defined?(Rails)
    CandidateSet.new(query_names: queries || [], candidates: [], authority: authority_metadata)
  end

  def fetch(source:, id:)
    source = source.to_s
    id = id.to_s
    return nil if source.empty? || id.empty?
    return corpus_profile(id) if source == "corpus"
    return nil unless @store.available?
    return nil if source == "cbdb" && !@store.cbdb_available?
    return nil if source != "cbdb" && !@store.historical_available?

    @store.with_database do |db|
      source == "cbdb" ? fetch_cbdb(db, id) : fetch_historical(db, source, id)
    end
  end

  def corpus_profile(name)
    index = CorpusCatalogueIndex.load
    person = index.corpus_person(name)
    return nil unless person

    {
      "source" => "corpus",
      "id" => person.fetch("name_key"),
      "label" => person.fetch("name"),
      "names" => [{ "name" => person.fetch("name"), "primary" => true, "explicit" => true }],
      "roles" => person.fetch("roles"),
      "authority_label" => "Fanya Hanwen Corpus",
      "source_citations" => [],
      "corpus_only" => true
    }
  rescue CorpusCatalogueIndex::CacheMissing
    nil
  end

  def corpus_contributions(person)
    names = Array(person && person["names"]).map { |entry| entry.is_a?(Hash) ? entry["name"].to_s : entry.to_s }
    names << person["label"].to_s if person
    names = names.flat_map do |value|
      fragments = han_name_fragments(value)
      fragments.empty? ? [value.to_s] : fragments
    end.uniq
    CorpusCatalogueIndex.load.works_for_person(names: names)
  rescue CorpusCatalogueIndex::CacheMissing
    []
  end

  # Kept as a Ruby-level compatibility alias for callers written against the
  # first unreleased author-page prototype. Public presentation now describes
  # all credited corpus contributions.
  alias corpus_works corpus_contributions

  private

  def authority_name_forms(name)
    source = name.to_s.strip
    return [] if source.empty?

    options = source.each_char.map { |character| AuthorityHanVariantRegistry.instance.forms_for(character).to_a.sort }
    forms = [source]
    source_chars = source.each_char.to_a
    options.each_with_index do |character_forms, index|
      character_forms.each do |replacement|
        next if replacement == source_chars[index]
        chars = source_chars.dup
        chars[index] = replacement
        forms << chars.join
      end
    end
    forms.uniq.first(64)
  rescue StandardError
    [source]
  end

  def cbdb_person_candidates(db, matched_query, names)
    return [] unless table_exists?(db, "cbdb", "BIOG_MAIN")

    biog_columns = table_columns(db, "cbdb", "BIOG_MAIN")
    id_column = choose_column(biog_columns, %w[c_personid person_id])
    name_column = choose_column(biog_columns, %w[c_name_chn c_name_ch name_chn])
    return [] unless id_column && name_column

    ids = []
    placeholders = (["?"] * names.length).join(",")
    db.execute(
      "SELECT #{quote_identifier(id_column)} AS person_id, #{quote_identifier(name_column)} AS matched_name FROM cbdb.BIOG_MAIN WHERE #{quote_identifier(name_column)} IN (#{placeholders})",
      names
    ).each { |row| ids << [row["person_id"].to_s, row["matched_name"].to_s, true] }

    if table_exists?(db, "cbdb", "ALTNAME_DATA")
      alt_columns = table_columns(db, "cbdb", "ALTNAME_DATA")
      alt_person = choose_column(alt_columns, %w[c_personid person_id])
      alt_name = choose_column(alt_columns, %w[c_alt_name_chn c_altname_chn c_name_chn alt_name_chn])
      if alt_person && alt_name
        db.execute(
          "SELECT #{quote_identifier(alt_person)} AS person_id, #{quote_identifier(alt_name)} AS matched_name FROM cbdb.ALTNAME_DATA WHERE #{quote_identifier(alt_name)} IN (#{placeholders})",
          names
        ).each { |row| ids << [row["person_id"].to_s, row["matched_name"].to_s, false] }
      end
    end

    ids.uniq { |id, _name, _primary| id }.filter_map do |person_id, matched_name, primary|
      person = fetch_cbdb(db, person_id)
      next unless person

      {
        "id" => person_id,
        "label" => person["label"],
        "local_label" => person["label"],
        "romanized" => person["romanized"],
        "year_start" => person["year_start"],
        "year_end" => person["year_end"],
        "polity" => person["polity"],
        "places" => person["places"],
        "offices" => person["offices"],
        "authority_source" => "cbdb",
        "source_label" => person["authority_label"],
        "source_url" => person["source_url"],
        "matched_query" => matched_query,
        "matched_name" => matched_name,
        "confidence" => primary && matched_name == matched_query ? "high" : "possible"
      }.compact
    end
  end

  def historical_person_candidates(db, matched_query, names)
    return [] unless table_exists?(db, "historical", "names") && table_exists?(db, "historical", "people")

    placeholders = (["?"] * names.length).join(",")
    rows = db.execute(<<~SQL, names)
      SELECT n.source, n.entity_id, n.name_chn, n.primary_name, n.explicit_name,
             p.label, p.local_label, p.romanized, p.year_start, p.year_end,
             p.polity, p.places, p.roles, p.source_url
      FROM historical.names n
      JOIN historical.people p ON p.source = n.source AND p.entity_id = n.entity_id
      WHERE n.name_chn IN (#{placeholders})
      ORDER BY n.explicit_name DESC, n.primary_name DESC, n.source, n.entity_id
    SQL

    rows.map do |row|
      exact = row["name_chn"].to_s == matched_query
      explicit = row["explicit_name"].to_i == 1
      {
        "id" => row["entity_id"].to_s,
        "label" => row["label"].to_s.presence || row["name_chn"].to_s,
        "local_label" => row["local_label"].to_s.presence,
        "romanized" => row["romanized"].to_s.presence,
        "year_start" => integer_or_nil(row["year_start"]),
        "year_end" => integer_or_nil(row["year_end"]),
        "polity" => row["polity"].to_s.presence,
        "places" => split_values(row["places"]),
        "roles" => split_values(row["roles"]),
        "authority_source" => row["source"].to_s,
        "source_label" => historical_source_label(row["source"]),
        "source_url" => row["source_url"].to_s.presence,
        "matched_query" => matched_query,
        "matched_name" => row["name_chn"].to_s,
        "confidence" => explicit && exact ? "high" : "possible"
      }.compact
    end
  end

  def authority_metadata
    metadata = begin
      @store.metadata.to_h.stringify_keys
    rescue StandardError => e
      Rails.logger&.warn("[authority] person metadata summary unavailable: #{e.class}: #{e.message}") if defined?(Rails)
      {}
    end

    metadata.merge(
      "cbdb_available" => (@store.respond_to?(:cbdb_available?) && @store.cbdb_available?),
      "cbdb_lookup_available" => (@store.respond_to?(:lookup_available?) && @store.lookup_available?),
      "historical_available" => (@store.respond_to?(:historical_available?) && @store.historical_available?)
    )
  rescue StandardError
    metadata || {}
  end

  def fetch_historical(db, source, id)
    return nil unless table_exists?(db, "historical", "people")

    row = db.get_first_row(
      "SELECT * FROM historical.people WHERE source = ? AND entity_id = ? LIMIT 1",
      [source, id]
    )
    return nil unless row

    names = db.execute(
      "SELECT name_chn, primary_name, explicit_name, derivation FROM historical.names WHERE source = ? AND entity_id = ? ORDER BY primary_name DESC, explicit_name DESC, name_length DESC, name_chn",
      [source, id]
    ).map do |name_row|
      {
        "name" => name_row["name_chn"].to_s,
        "primary" => name_row["primary_name"].to_i == 1,
        "explicit" => name_row["explicit_name"].to_i == 1,
        "derivation" => name_row["derivation"].to_s
      }
    end

    {
      "source" => source,
      "id" => id,
      "label" => row["label"].to_s.presence || names.first&.dig("name") || id,
      "local_label" => row["local_label"].to_s.presence,
      "romanized" => row["romanized"].to_s.presence,
      "year_start" => integer_or_nil(row["year_start"]),
      "year_end" => integer_or_nil(row["year_end"]),
      "date_label" => row["date_label"].to_s.presence,
      "country" => row["country"].to_s.presence,
      "polity" => row["polity"].to_s.presence,
      "roles" => split_values(row["roles"]),
      "places" => split_values(row["places"]),
      "names" => names,
      "source_url" => row["source_url"].to_s.presence,
      "source_citations" => split_lines(row["source_citations"]),
      "chronology_confidence" => row["chronology_confidence"].to_s.presence,
      "external_ids" => row["external_ids"].to_s.presence,
      "authority_label" => historical_source_label(source)
    }.compact
  end

  def fetch_cbdb(db, id)
    return nil unless table_exists?(db, "cbdb", "BIOG_MAIN")

    columns = table_columns(db, "cbdb", "BIOG_MAIN")
    id_column = choose_column(columns, %w[c_personid person_id])
    return nil unless id_column

    row = db.get_first_row(
      "SELECT * FROM cbdb.#{quote_identifier('BIOG_MAIN')} WHERE #{quote_identifier(id_column)} = ? LIMIT 1",
      [id]
    )
    return nil unless row

    label = first_value(row, %w[c_name_chn c_name_ch name_chn]).to_s.presence || id
    romanized = first_value(row, %w[c_name c_name_eng c_name_trans]).to_s.presence
    year_start = first_integer(row, %w[c_birthyear c_fl_earliest_year c_index_year c_firstyear])
    year_end = first_integer(row, %w[c_deathyear c_fl_latest_year c_index_year c_lastyear])
    dynasty = cbdb_dynasty(db, row)
    names = cbdb_names(db, id, label)

    {
      "source" => "cbdb",
      "id" => id,
      "label" => label,
      "romanized" => romanized,
      "year_start" => year_start,
      "year_end" => year_end,
      "date_label" => [year_label(year_start), year_label(year_end)].compact.uniq.join("–").presence,
      "polity" => dynasty,
      "names" => names,
      "places" => cbdb_addresses(db, id),
      "offices" => cbdb_offices(db, id),
      "source_url" => HistoricalAuthorityStore::CBDB_URL,
      "source_citations" => [CBDB_APA_CITATION],
      "authority_label" => "China Biographical Database (CBDB)",
      "authority_license" => HistoricalAuthorityStore::CBDB_LICENSE,
      "raw_summary" => compact_cbdb_summary(row)
    }.compact
  end

  def cbdb_names(db, person_id, primary)
    output = [{ "name" => primary, "primary" => true, "explicit" => true }]
    return output unless table_exists?(db, "cbdb", "ALTNAME_DATA")

    columns = table_columns(db, "cbdb", "ALTNAME_DATA")
    person_column = choose_column(columns, %w[c_personid person_id])
    name_column = choose_column(columns, %w[c_alt_name_chn c_altname_chn c_name_chn alt_name_chn])
    type_column = choose_column(columns, %w[c_alt_name_type_code c_altname_type_code alt_name_type_code])
    return output unless person_column && name_column

    db.execute(
      "SELECT * FROM cbdb.#{quote_identifier('ALTNAME_DATA')} WHERE #{quote_identifier(person_column)} = ?",
      [person_id]
    ).each do |row|
      name = row[name_column].to_s.strip
      next if name.empty?
      output << {
        "name" => name,
        "primary" => false,
        "explicit" => true,
        "type_code" => type_column ? row[type_column].to_s.presence : nil
      }.compact
    end
    output.uniq { |entry| entry["name"] }
  end

  def cbdb_dynasty(db, biog_row)
    code = first_value(biog_row, %w[c_dy c_dynasty c_dynasty_id])
    return nil if code.to_s.empty? || !table_exists?(db, "cbdb", "DYNASTIES")

    columns = table_columns(db, "cbdb", "DYNASTIES")
    code_column = choose_column(columns, %w[c_dy c_dynasty c_dynasty_id])
    label_column = choose_column(columns, %w[c_dynasty_chn c_dynasty c_name_chn dynasty_chn])
    return nil unless code_column && label_column

    db.get_first_value(
      "SELECT #{quote_identifier(label_column)} FROM cbdb.#{quote_identifier('DYNASTIES')} WHERE #{quote_identifier(code_column)} = ? LIMIT 1",
      [code]
    ).to_s.presence
  end

  def cbdb_addresses(db, person_id)
    return [] unless table_exists?(db, "cbdb", "ADDR_CODES")

    code_columns = table_columns(db, "cbdb", "ADDR_CODES")
    id_column = choose_column(code_columns, %w[c_addr_id c_addrid addr_id])
    label_column = choose_column(code_columns, %w[c_name_chn c_addr_chn c_addr_name_chn name_chn])
    return [] unless id_column && label_column

    output = linked_cbdb_rows(db, %w[BIOG_ADDR_DATA BIOG_ADDR_DATA_TMP], person_id).filter_map do |row|
      addr_id = first_value(row, %w[c_addr_id c_addrid addr_id])
      next if addr_id.to_s.empty?
      label = cbdb_address_label(db, id_column, label_column, addr_id)
      next unless label

      years = [first_integer(row, %w[c_firstyear firstyear]), first_integer(row, %w[c_lastyear lastyear])].compact
      { "label" => label, "id" => addr_id.to_s, "years" => years, "relation" => "biographical_address" }.compact
    end

    # CBDB's primary person table carries the index address used by its own
    # person browser. Surface it as useful context even when no BIOG_ADDR_DATA
    # row exists for the person.
    if table_exists?(db, "cbdb", "BIOG_MAIN")
      columns = table_columns(db, "cbdb", "BIOG_MAIN")
      person_column = choose_column(columns, %w[c_personid person_id])
      index_column = choose_column(columns, %w[c_index_addr_id index_addr_id])
      if person_column && index_column
        index_addr_id = db.get_first_value(
          "SELECT #{quote_identifier(index_column)} FROM cbdb.#{quote_identifier('BIOG_MAIN')} WHERE #{quote_identifier(person_column)} = ? LIMIT 1",
          [person_id]
        )
        if index_addr_id.to_s.present? && index_addr_id.to_i != 0
          label = cbdb_address_label(db, id_column, label_column, index_addr_id)
          output.unshift({ "label" => label, "id" => index_addr_id.to_s, "relation" => "index_address" }) if label
        end
      end
    end

    output.uniq { |entry| [entry["id"], entry["years"], entry["relation"]] }.first(100)
  end

  def cbdb_address_label(db, id_column, label_column, addr_id)
    db.get_first_value(
      "SELECT #{quote_identifier(label_column)} FROM cbdb.#{quote_identifier('ADDR_CODES')} WHERE #{quote_identifier(id_column)} = ? LIMIT 1",
      [addr_id]
    ).to_s.presence
  end

  def cbdb_offices(db, person_id)
    links = linked_cbdb_rows(db, %w[POSTED_TO_OFFICE_DATA POSTED_TO_OFFICE_DATA_TMP], person_id)
    return [] if links.empty? || !table_exists?(db, "cbdb", "OFFICE_CODES")

    code_columns = table_columns(db, "cbdb", "OFFICE_CODES")
    id_column = choose_column(code_columns, %w[c_office_id c_officeid office_id])
    label_column = choose_column(code_columns, %w[c_office_chn c_name_chn c_office_name_chn office_chn])
    return [] unless id_column && label_column

    links.filter_map do |row|
      office_id = first_value(row, %w[c_office_id c_officeid office_id])
      next if office_id.to_s.empty?
      label = db.get_first_value(
        "SELECT #{quote_identifier(label_column)} FROM cbdb.#{quote_identifier('OFFICE_CODES')} WHERE #{quote_identifier(id_column)} = ? LIMIT 1",
        [office_id]
      ).to_s.presence
      next unless label

      years = [first_integer(row, %w[c_firstyear firstyear]), first_integer(row, %w[c_lastyear lastyear])].compact
      { "label" => label, "id" => office_id.to_s, "years" => years }.compact
    end.uniq { |entry| [entry["id"], entry["years"]] }.first(150)
  end

  def linked_cbdb_rows(db, tables, person_id)
    table = tables.find { |name| table_exists?(db, "cbdb", name) }
    return [] unless table

    columns = table_columns(db, "cbdb", table)
    person_column = choose_column(columns, %w[c_personid person_id])
    return [] unless person_column

    db.execute(
      "SELECT * FROM cbdb.#{quote_identifier(table)} WHERE #{quote_identifier(person_column)} = ? LIMIT 500",
      [person_id]
    )
  end

  def compact_cbdb_summary(row)
    wanted = %w[c_index_year c_female c_by_nh_code c_notes c_surname c_mingzi]
    wanted.each_with_object({}) do |key, output|
      value = row[key]
      output[key] = value unless value.nil? || value.to_s.empty?
    end
  end

  def han_name_fragments(value)
    value.to_s.scan(/\p{Han}{2,16}/).map(&:strip)
  end

  def item_start(item) = (item[:start] || item["start"]).to_i
  def item_end(item) = (item[:end] || item["end"]).to_i

  def table_exists?(db, schema, table)
    db.get_first_value("SELECT 1 FROM #{schema}.sqlite_master WHERE type='table' AND name=? LIMIT 1", [table]).to_i == 1
  end

  def table_columns(db, schema, table)
    db.execute("PRAGMA #{schema}.table_info(#{quote_identifier(table)})").map { |row| row["name"].to_s }
  end

  def choose_column(columns, candidates)
    lookup = columns.to_h { |column| [column.downcase, column] }
    candidates.each { |candidate| return lookup[candidate.downcase] if lookup[candidate.downcase] }
    nil
  end

  def first_value(row, candidates)
    candidates.each do |key|
      value = row[key]
      return value unless value.nil? || value.to_s.empty?
    end
    nil
  end

  def first_integer(row, candidates)
    candidates.each do |key|
      value = integer_or_nil(row[key])
      return value if value
    end
    nil
  end

  def integer_or_nil(value)
    integer = if value.is_a?(Numeric)
      value.to_i
    else
      text = value.to_s.strip
      text.match?(/\A-?\d+\z/) ? text.to_i : nil
    end
    # CBDB uses zero as an unknown-date sentinel. Historical chronology has no
    # year zero, so never present that sentinel as “0 CE” on an author page.
    integer&.zero? ? nil : integer
  end

  def split_values(value)
    value.to_s.split(/[\n;；,，]+/).map(&:strip).reject(&:empty?)
  end

  def split_lines(value)
    value.to_s.split(/\r?\n/).map(&:strip).reject(&:empty?)
  end

  def historical_source_label(source)
    {
      "fanya_supplementary" => "Fanya historical supplementary authority",
      "wikidata_east_asia" => "Wikidata East Asia authority",
      "wikidata_east_asia+wikipedia_ruler_list" => "Wikidata + Wikipedia ruler authority",
      "wikipedia_ruler_list" => "Wikipedia ruler authority"
    }.fetch(source.to_s, source.to_s)
  end

  def year_label(value)
    return nil unless value
    value.to_i < 0 ? "#{value.to_i.abs} BCE" : "#{value.to_i} CE"
  end

  def quote_identifier(value)
    %Q{"#{value.to_s.gsub('"', '""')}"}
  end
end
