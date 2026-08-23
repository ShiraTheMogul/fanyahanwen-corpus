# frozen_string_literal: true

# Keep the disposable historical authority index on the same tightly bounded
# orthography rules used by the interactive resolver and auto-annotator.
#
# Project-maintained people are deliberately ordinary spreadsheets: Shang/Xia
# stay in their existing workbook, while the received high-antiquity traditions
# live in three_sovereigns_five_emperors.xlsx. This keeps the authority data
# directly editable without turning corpus metadata into an authority database.
module HistoricalAuthorityIndexStaticNames
  HIGH_ANTIQUITY_SOURCE = "fanya_high_antiquity"
  AUTHORITY_SCHEMA_REVISION = "high-antiquity-clans-v1"
  HIGH_ANTIQUITY_REQUIRED_HEADERS = (HistoricalAuthorityIndex::REQUIRED_HEADERS + %w[
    chronology_confidence source_ids clans
  ]).uniq.freeze

  # Migration support for the clearer workbook name. A ZIP overlay cannot delete
  # shang_people.xlsx when a repository already has it, so both names are accepted.
  # Once shang_xia.xlsx exists, the base index sees that path too and no caller has
  # to know about the old filename.
  def self.prepended(base)
    preferred = Rails.root.join("data", "shang_xia.xlsx")
    return unless preferred.file?
    return if base::SUPPLEMENTARY_SOURCE_PATH.expand_path == preferred.expand_path

    base.send(:remove_const, :SUPPLEMENTARY_SOURCE_PATH)
    base.const_set(:SUPPLEMENTARY_SOURCE_PATH, preferred)
  end

  private

  def high_antiquity_source_path
    Rails.root.join("data", "three_sovereigns_five_emperors.xlsx")
  end

  def source_fingerprint(snapshot)
    digest = Digest::SHA256.new
    digest << "historical-authority-v#{HistoricalAuthorityIndex::VERSION}\0"
    digest << AUTHORITY_SCHEMA_REVISION
    digest << "\0"
    if HistoricalAuthorityIndex::SUPPLEMENTARY_SOURCE_PATH.file?
      digest << Digest::SHA256.file(HistoricalAuthorityIndex::SUPPLEMENTARY_SOURCE_PATH).hexdigest
    else
      digest << "no-shang-xia-workbook"
    end
    digest << "\0"
    if high_antiquity_source_path.file?
      digest << Digest::SHA256.file(high_antiquity_source_path).hexdigest
    else
      digest << "no-high-antiquity-workbook"
    end
    digest << "\0"
    if HistoricalAuthorityIndex::CURATED_ERA_SOURCE_PATH.file?
      digest << Digest::SHA256.file(HistoricalAuthorityIndex::CURATED_ERA_SOURCE_PATH).hexdigest
    else
      digest << "no-curated-era-source"
    end
    digest << "\0"
    digest << Digest::SHA256.hexdigest(JSON.generate(snapshot || {}))
    digest << "\0"
    digest << AuthorityHanVariantRegistry.instance.version
    digest.hexdigest
  end

  # HistoricalAuthorityIndex#rebuild! already calls this one import hook. Handle
  # both human-maintained workbooks here so the SQLite cache receives one coherent
  # set of people and names.
  def import_supplementary!(db, expander, counts)
    require "roo"

    ensure_clan_schema!(db)
    import_shang_xia_workbook!(db, expander, counts) if HistoricalAuthorityIndex::SUPPLEMENTARY_SOURCE_PATH.file?
    import_high_antiquity_workbook!(db, expander, counts) if high_antiquity_source_path.file?
  end

  def import_shang_xia_workbook!(db, expander, counts)
    workbook = Roo::Excelx.new(HistoricalAuthorityIndex::SUPPLEMENTARY_SOURCE_PATH.to_s)
    HistoricalAuthorityIndex::SUPPLEMENTARY_SHEETS.each do |sheet_name|
      next unless workbook.sheets.include?(sheet_name)

      each_people_sheet_row(workbook, sheet_name, HistoricalAuthorityIndex::REQUIRED_HEADERS) do |row, row_number|
        person_id = normalize_identifier(row["person_id"])
        name_han = cell_text(row["name_han"])
        raise "#{sheet_name} row #{row_number}: person_id is required" if person_id.empty?
        raise "#{sheet_name} row #{row_number}: name_han is required" if name_han.empty?

        roles = cell_text(row["roles"])
        shang_diviner = sheet_name == "Shang" && roles.include?("巫") ? 1 : 0
        entity_id = "#{sheet_name}:#{person_id}"
        insert_authority_person!(
          db,
          source: "fanya_supplementary",
          entity_id: entity_id,
          name_han: name_han,
          romanized: cell_text(row["primary_name"]).presence,
          year_start: normalize_year(row["year_start"]),
          year_end: normalize_year(row["year_end"]),
          date_label: cell_text(row["date_label"]).presence,
          polity: cell_text(row["polity"]).presence,
          roles: roles.presence,
          places: cell_text(row["places"]).presence,
          source_url: repository_data_path(HistoricalAuthorityIndex::SUPPLEMENTARY_SOURCE_PATH),
          source_citations: cell_text(row["source_citations"]).presence,
          chronology_confidence: nil,
          external_ids: cell_text(row["external_ids"]).presence,
          shang_diviner: shang_diviner
        )
        counts["people"] += 1
        counts["supplementary_people"] += 1
        counts["shang_diviners"] += 1 if shang_diviner == 1

        explicit_names = [name_han, *split_aliases(row["aliases"])].uniq
        insert_person_names!(db, "fanya_supplementary", entity_id, explicit_names, name_han, expander, counts)
      end
    end
  ensure
    workbook&.close rescue nil
  end

  def import_high_antiquity_workbook!(db, expander, counts)
    workbook = Roo::Excelx.new(high_antiquity_source_path.to_s)
    raise "three_sovereigns_five_emperors.xlsx is missing People sheet" unless workbook.sheets.include?("People")

    sources = workbook_sources(workbook)
    clans = Hash.new do |hash, name|
      hash[name] = {
        member_ids: [],
        period_labels: [],
        chronology_confidences: [],
        source_urls: [],
        source_citations: []
      }
    end

    each_people_sheet_row(workbook, "People", HIGH_ANTIQUITY_REQUIRED_HEADERS) do |row, row_number|
      person_id = normalize_identifier(row["person_id"])
      name_han = cell_text(row["name_han"])
      raise "People row #{row_number}: person_id is required" if person_id.empty?
      raise "People row #{row_number}: name_han is required" if name_han.empty?

      source_rows = split_authority_values(row["source_ids"]).filter_map { |source_id| sources[source_id] }
      citations = cell_text(row["source_citations"]).presence
      citations ||= source_rows.filter_map { |source| source["citation"].to_s.strip.presence }.join("\n").presence

      insert_authority_person!(
        db,
        source: HIGH_ANTIQUITY_SOURCE,
        entity_id: person_id,
        name_han: name_han,
        romanized: cell_text(row["primary_name"]).presence,
        year_start: normalize_year(row["year_start"]),
        year_end: normalize_year(row["year_end"]),
        date_label: cell_text(row["date_label"]).presence,
        polity: cell_text(row["polity"]).presence,
        roles: cell_text(row["roles"]).presence,
        places: cell_text(row["places"]).presence,
        source_url: source_rows.first&.dig("url").to_s.presence,
        source_citations: citations,
        chronology_confidence: cell_text(row["chronology_confidence"]).presence,
        external_ids: cell_text(row["external_ids"]).presence,
        shang_diviner: 0
      )
      counts["people"] += 1
      counts["high_antiquity_people"] += 1

      explicit_names = [name_han, *split_aliases(row["aliases"])].uniq
      insert_person_names!(db, HIGH_ANTIQUITY_SOURCE, person_id, explicit_names, name_han, expander, counts)
      collect_high_antiquity_clans!(clans, row, person_id, source_rows, citations)
    end

    import_high_antiquity_clans!(db, expander, clans, counts)
  ensure
    workbook&.close rescue nil
  end

  def ensure_clan_schema!(db)
    db.execute_batch <<~SQL
      CREATE TABLE IF NOT EXISTS clans (
        source TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        country TEXT,
        label TEXT,
        period_labels TEXT,
        chronology_confidence TEXT,
        source_url TEXT,
        source_citations TEXT,
        PRIMARY KEY (source, entity_id)
      ) WITHOUT ROWID;

      CREATE TABLE IF NOT EXISTS clan_names (
        prefix TEXT NOT NULL,
        name_length INTEGER NOT NULL,
        name_chn TEXT NOT NULL,
        source TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        primary_name INTEGER NOT NULL DEFAULT 0,
        explicit_name INTEGER NOT NULL DEFAULT 0,
        derivation TEXT NOT NULL,
        PRIMARY KEY (prefix, name_chn, source, entity_id)
      ) WITHOUT ROWID;

      CREATE INDEX IF NOT EXISTS clan_names_by_exact ON clan_names(name_chn, name_length);

      CREATE TABLE IF NOT EXISTS clan_members (
        clan_source TEXT NOT NULL,
        clan_id TEXT NOT NULL,
        person_source TEXT NOT NULL,
        person_id TEXT NOT NULL,
        PRIMARY KEY (clan_source, clan_id, person_source, person_id)
      ) WITHOUT ROWID;
    SQL
  end

  # The People sheet is the editable source of clan membership. 氏 values are
  # stored as their own authority entities; they are not aliases, places, or
  # polities. Multiple people can point to the same clan without duplicating the
  # clan record in the disposable SQLite index.
  def collect_high_antiquity_clans!(clans, row, person_id, source_rows, citations)
    split_authority_values(row["clans"]).each do |clan_name|
      next unless han_name?(clan_name)

      record = clans[clan_name]
      record[:member_ids] << person_id
      record[:period_labels] << cell_text(row["period"])
      record[:chronology_confidences] << cell_text(row["chronology_confidence"])
      record[:source_urls].concat(source_rows.filter_map { |source| source["url"].to_s.strip.presence })
      record[:source_citations].concat(citations.to_s.lines.map(&:strip).reject(&:empty?))
    end
  end

  def import_high_antiquity_clans!(db, expander, clans, counts)
    clans.each do |clan_name, record|
      clan_id = "clan:#{clan_name}"
      period_labels = record[:period_labels].map(&:to_s).map(&:strip).reject(&:empty?).uniq.join("; ").presence
      chronology_confidence = record[:chronology_confidences].map(&:to_s).map(&:strip).reject(&:empty?).uniq.join("; ").presence
      source_url = record[:source_urls].map(&:to_s).map(&:strip).reject(&:empty?).uniq.first
      source_citations = record[:source_citations].map(&:to_s).map(&:strip).reject(&:empty?).uniq.join("\n").presence

      db.execute(
        <<~SQL,
          INSERT OR REPLACE INTO clans (
            source, entity_id, country, label, period_labels, chronology_confidence,
            source_url, source_citations
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        [
          HIGH_ANTIQUITY_SOURCE, clan_id, "China", clan_name, period_labels, chronology_confidence,
          source_url, source_citations
        ]
      )
      counts["clans"] += 1
      counts["high_antiquity_clans"] += 1

      insert_clan_names!(db, HIGH_ANTIQUITY_SOURCE, clan_id, [clan_name], clan_name, expander, counts)
      record[:member_ids].map(&:to_s).reject(&:empty?).uniq.each do |person_id|
        db.execute(
          "INSERT OR REPLACE INTO clan_members (clan_source, clan_id, person_source, person_id) VALUES (?, ?, ?, ?)",
          [HIGH_ANTIQUITY_SOURCE, clan_id, HIGH_ANTIQUITY_SOURCE, person_id]
        )
        counts["clan_memberships"] += 1
      end
    end
  end

  def insert_clan_names!(db, source, entity_id, names, primary_name, expander, counts)
    expanded_name_records(names, primary_name, expander).each do |record|
      name = record.fetch(:name).to_s
      length = name.each_char.count
      next if length < 2

      prefix = name.each_char.take(2).join
      db.execute(
        <<~SQL,
          INSERT OR REPLACE INTO clan_names (
            prefix, name_length, name_chn, source, entity_id,
            primary_name, explicit_name, derivation
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        [
          prefix, length, name, source, entity_id,
          record[:primary] ? 1 : 0, record[:explicit] ? 1 : 0, record.fetch(:derivation).to_s
        ]
      )
      counts["names"] += 1
      counts["clan_names"] += 1
    end
  end

  def each_people_sheet_row(workbook, sheet_name, required_headers)
    sheet = workbook.sheet(sheet_name)
    headers = sheet.row(1).map { |value| value.to_s.strip }
    missing = required_headers - headers
    raise "#{sheet_name} is missing required columns: #{missing.join(', ')}" if missing.any?

    (2..sheet.last_row.to_i).each do |row_number|
      values = sheet.row(row_number)
      row = headers.each_with_index.to_h { |header, index| [header, values[index]] }
      next if row.except("person_id").values.all? { |value| blank_cell?(value) }

      yield row, row_number
    end
  end

  def workbook_sources(workbook)
    return {} unless workbook.sheets.include?("Sources")

    sheet = workbook.sheet("Sources")
    headers = sheet.row(1).map { |value| value.to_s.strip }
    required = %w[source_id citation url]
    missing = required - headers
    raise "Sources is missing required columns: #{missing.join(', ')}" if missing.any?

    (2..sheet.last_row.to_i).each_with_object({}) do |row_number, output|
      values = sheet.row(row_number)
      row = headers.each_with_index.to_h { |header, index| [header, values[index]] }
      source_id = cell_text(row["source_id"])
      next if source_id.empty?

      output[source_id] = row.transform_values { |value| cell_text(value) }
    end
  end

  def split_authority_values(value)
    value.to_s.split(/[;；\n]+/).map(&:strip).reject(&:empty?)
  end

  def insert_authority_person!(db, source:, entity_id:, name_han:, romanized:, year_start:, year_end:,
    date_label:, polity:, roles:, places:, source_url:, source_citations:, chronology_confidence:,
    external_ids:, shang_diviner:)
    db.execute(
      <<~SQL,
        INSERT OR REPLACE INTO people (
          source, entity_id, country, label, local_label, romanized,
          year_start, year_end, date_label, polity, roles, places,
          source_url, source_citations, chronology_confidence, external_ids, shang_diviner
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      [
        source, entity_id, "China", name_han, nil, romanized,
        year_start, year_end, date_label, polity, roles, places,
        source_url, source_citations, chronology_confidence, external_ids, shang_diviner
      ]
    )
  end

  def repository_data_path(path)
    "viewer/data/#{Pathname(path.to_s).basename}"
  end

  # The base rebuild creates an AuthorityNameExpander for all historical names.
  # Ignore that broad-registry instance when records are actually expanded and
  # use the authority-specific registry. This keeps the rebuilt SQLite contents
  # consistent with the fingerprint above.
  def expanded_name_records(names, primary_name, _expander)
    expander = (@authority_name_expander ||= AuthorityNameExpander.new(registry: AuthorityHanVariantRegistry.instance))
    output = {}
    Array(names).map(&:to_s).map(&:strip).reject(&:empty?).uniq.each do |name|
      next unless han_name?(name)

      output[name] ||= {
        name: name,
        primary: name == primary_name,
        explicit: true,
        derivation: "explicit"
      }
      expander.expand(name).each do |form|
        output[form.name] ||= {
          name: form.name,
          primary: false,
          explicit: false,
          derivation: form.derivation
        }
      end
    end
    output.values
  end

  def write_metadata!(db, fingerprint, snapshot, counts)
    values = {
      "version" => HistoricalAuthorityIndex::VERSION.to_s,
      "fingerprint" => fingerprint,
      "authority_schema_revision" => AUTHORITY_SCHEMA_REVISION,
      "built_at_utc" => Time.now.utc.iso8601,
      "supplementary_filename" => HistoricalAuthorityIndex::SUPPLEMENTARY_SOURCE_PATH.file? ? HistoricalAuthorityIndex::SUPPLEMENTARY_SOURCE_PATH.basename.to_s : "",
      "supplementary_sha256" => HistoricalAuthorityIndex::SUPPLEMENTARY_SOURCE_PATH.file? ? Digest::SHA256.file(HistoricalAuthorityIndex::SUPPLEMENTARY_SOURCE_PATH).hexdigest : "",
      "high_antiquity_filename" => high_antiquity_source_path.file? ? high_antiquity_source_path.basename.to_s : "",
      "high_antiquity_sha256" => high_antiquity_source_path.file? ? Digest::SHA256.file(high_antiquity_source_path).hexdigest : "",
      "curated_era_filename" => HistoricalAuthorityIndex::CURATED_ERA_SOURCE_PATH.file? ? HistoricalAuthorityIndex::CURATED_ERA_SOURCE_PATH.basename.to_s : "",
      "curated_era_sha256" => HistoricalAuthorityIndex::CURATED_ERA_SOURCE_PATH.file? ? Digest::SHA256.file(HistoricalAuthorityIndex::CURATED_ERA_SOURCE_PATH).hexdigest : "",
      "east_asia_snapshot_version" => snapshot.to_h["version"].to_s,
      "east_asia_generated_at_utc" => snapshot.to_h["generated_at_utc"].to_s,
      "east_asia_snapshot_sha256" => Digest::SHA256.hexdigest(JSON.generate(snapshot || {})),
      "east_asia_wikidata_license" => snapshot.to_h["wikidata_license"].to_s,
      "east_asia_wikipedia_license" => snapshot.to_h["wikipedia_discovery_license"].to_s,
      "east_asia_sources_json" => JSON.generate(snapshot.to_h["sources"] || {}),
      "equivalence_version" => AuthorityHanVariantRegistry.instance.version
    }.merge(counts.transform_values(&:to_s))

    values.each do |key, value|
      db.execute("INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)", [key, value.to_s])
    end
  end
end
