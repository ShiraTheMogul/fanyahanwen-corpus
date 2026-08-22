# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "openssl"
require "set"
require "time"
require "uri"

# Maintains a small, rebuildable snapshot of Japanese, Korean and Vietnamese
# rulers and era names. Wikidata supplies structured entity data (CC0); the
# canonical Wikipedia ruler/era lists provide discovery plus table-level
# chronology, local-use intervals and historical name enrichment (CC BY-SA).
class EastAsianAuthorityUpdater
  SNAPSHOT_PATH = "east-asian-authority-v4.json.gz"
  VERSION = 4
  DEFAULT_TTL = 86_400
  USER_AGENT = "FanyaHanwenCorpus/1.0 (historical authority maintenance)"

  SOURCES = {
    "Japan" => {
      ruler_page: "List of emperors of Japan",
      era_page: "Japanese era name"
    },
    "Korea" => {
      ruler_page: "List of monarchs of Korea",
      era_page: "Korean era name"
    },
    "Vietnam" => {
      ruler_page: "List of monarchs of Vietnam",
      era_page: "Vietnamese era name"
    }
  }.freeze

  # Direct East Asian name properties plus native/birth names. The reading
  # properties below are harvested separately for display/search provenance.
  NAME_PROPERTIES = %w[P1477 P1559 P1705 P1782 P1785 P1786 P1787].freeze
  READING_PROPERTIES = %w[P1721 P1814 P1942 P2001 P2125 P2440 P5139 P5625].freeze
  RULER_DESCRIPTION = /\b(?:king|queen regnant|emperor|empress regnant|monarch|ruler|sovereign)\b/i
  RULER_POSITION = /\b(?:king|queen|emperor|empress|monarch|ruler|sovereign|tenn[oō]|taewang|wang)\b/i
  ERA_DESCRIPTION = /\b(?:era name|reign era|imperial era|calendar era)\b/i

  Result = Data.define(:status, :payload, :path, :message) do
    def available? = payload.is_a?(Hash)
    def refreshed? = status == :refreshed
  end

  def self.refresh_if_needed!(cache_store: CorpusSearch::CacheStore.new, force: false, logger: Rails.logger)
    new(cache_store: cache_store, logger: logger).refresh_if_needed!(force: force)
  end

  def self.current(cache_store: CorpusSearch::CacheStore.new)
    cache_store.read_json(SNAPSHOT_PATH, freeze: true)
  end

  def initialize(cache_store:, logger: nil)
    @cache_store = cache_store
    @logger = logger
    @entity_cache = {}
  end

  def refresh_if_needed!(force: false)
    current = @cache_store.read_json(SNAPSHOT_PATH)
    unless force || stale?(current)
      return Result.new(
        status: :current,
        payload: current,
        path: @cache_store.absolute(SNAPSHOT_PATH).to_s,
        message: "East Asian ruler/era snapshot is current."
      )
    end

    payload = build_snapshot
    @cache_store.write_json(SNAPSHOT_PATH, payload)
    Result.new(
      status: :refreshed,
      payload: payload,
      path: @cache_store.absolute(SNAPSHOT_PATH).to_s,
      message: refreshed_message(payload)
    )
  rescue StandardError => e
    @logger&.warn("[authority] East Asian authority refresh failed: #{e.class}: #{e.message}")
    if current.is_a?(Hash)
      Result.new(
        status: :stale,
        payload: current,
        path: @cache_store.absolute(SNAPSHOT_PATH).to_s,
        message: "East Asian authority refresh failed; keeping the previous snapshot (#{e.class}: #{e.message})."
      )
    else
      Result.new(status: :unavailable, payload: nil, path: nil, message: "East Asian authority unavailable: #{e.class}: #{e.message}")
    end
  end

  private

  def stale?(payload)
    return true unless payload.is_a?(Hash) && payload["version"].to_i == VERSION

    generated = Time.iso8601(payload["generated_at_utc"].to_s)
    (Time.now.utc - generated) >= ttl_seconds
  rescue ArgumentError, TypeError
    true
  end

  def ttl_seconds
    Integer(ENV.fetch("EAST_ASIAN_AUTHORITY_TTL", DEFAULT_TTL.to_s))
  rescue ArgumentError, TypeError
    DEFAULT_TTL
  end

  def build_snapshot
    @degraded_sources = []
    @discovery_stats = {}
    ruler_rows = []
    era_rows = []

    SOURCES.each do |country, config|
      ruler_entities = optional_wikidata_entities_for_page(
        config.fetch(:ruler_page), country: country, kind: "rulers"
      )
      era_entities = optional_wikidata_entities_for_page(
        config.fetch(:era_page), country: country, kind: "eras"
      )

      country_rulers = build_rulers(country, ruler_entities)
      country_eras = build_eras(country, era_entities)
      ruler_title_map = enwiki_title_map(ruler_entities)
      era_title_map = enwiki_title_map(era_entities)

      ruler_list_rows = wikipedia_ruler_rows(
        config.fetch(:ruler_page),
        ruler_title_map,
        country: country
      )
      enrich_rulers_from_ruler_list!(
        country_rulers,
        ruler_list_rows,
        country: country
      )
      discarded_rulers = retain_canonical_records!(country_rulers, ruler_list_rows.keys)

      list_rows = wikipedia_era_rows(
        config.fetch(:era_page),
        country: country,
        ruler_title_map: ruler_title_map,
        era_title_map: era_title_map
      )
      enrich_rulers_from_list!(country_rulers, list_rows)
      merge_era_list_rows!(country_eras, list_rows)
      discarded_eras = retain_canonical_records!(country_eras, list_rows.map { |row| row["qid"] })
      @discovery_stats ||= {}
      @discovery_stats[country] = {
        "ruler_wikidata_candidates" => ruler_entities.length,
        "canonical_rulers" => country_rulers.length,
        "discarded_nonlist_rulers" => discarded_rulers,
        "era_wikidata_candidates" => era_entities.length,
        "canonical_era_records" => country_eras.length,
        "discarded_nonlist_eras" => discarded_eras
      }
      validate_country_coverage!(country, country_rulers, country_eras)

      ruler_rows.concat(country_rulers)
      era_rows.concat(country_eras)
    end

    ruler_rows = ruler_rows.uniq { |row| row.fetch("qid") }
    era_rows = era_rows.uniq { |row| row.fetch("qid") }
    infer_era_rulers!(era_rows, ruler_rows)

    {
      "version" => VERSION,
      "generated_at_utc" => Time.now.utc.iso8601,
      "wikidata_license" => "CC0-1.0",
      "wikipedia_discovery_license" => "CC-BY-SA-4.0",
      "sources" => SOURCES.transform_values do |config|
        {
          "ruler_list" => "https://en.wikipedia.org/wiki/#{config.fetch(:ruler_page).tr(' ', '_')}",
          "era_list" => "https://en.wikipedia.org/wiki/#{config.fetch(:era_page).tr(' ', '_')}"
        }
      end,
      "degraded_sources" => Array(@degraded_sources).uniq,
      "discovery_stats" => @discovery_stats,
      "rulers" => ruler_rows.sort_by { |row| [row["country"].to_s, row["reign_start_year"] || 99_999, row["qid"]] },
      "eras" => era_rows.sort_by { |row| [row["country"].to_s, row["start_year"] || row["local_use_start_year"] || 99_999, row["qid"]] }
    }
  end

  def refreshed_message(payload)
    base = "Refreshed East Asian authority snapshot: #{payload.fetch('rulers').length} rulers, #{payload.fetch('eras').length} era names."
    degraded = Array(payload["degraded_sources"])
    return base if degraded.empty?

    "#{base} Core Wikipedia lists were retained with #{degraded.length} degraded enrichment/API source(s); run authority:status for details."
  end

  def optional_wikidata_entities_for_page(page_title, country:, kind:)
    ids = wikidata_ids_linked_from(page_title)
    fetch_entities(ids)
  rescue StandardError => e
    note_degraded_source!("#{country} #{kind}: Wikidata enrichment unavailable (#{e.class}: #{e.message})")
    {}
  end

  def validate_country_coverage!(country, rulers, eras)
    raise "#{country} ruler list produced no usable ruler authorities" if rulers.empty?
    raise "#{country} era list produced no usable era authorities" if eras.empty?
  end

  # Wikipedia's dedicated ruler/era tables define the discovery scope. Wikidata
  # is enrichment only. Resolving every link on those long articles can pull in
  # foreign monarchs, relatives, historical examples and eras mentioned in prose;
  # assigning those linked entities to the page's country silently contaminates
  # the authority set. Keep only IDs represented by an actual canonical table row.
  def retain_canonical_records!(records, canonical_ids)
    allowed = Array(canonical_ids).map(&:to_s).reject(&:empty?).to_set
    before = records.length
    records.select! { |row| allowed.include?(row["qid"].to_s) }
    before - records.length
  end

  def note_degraded_source!(message)
    @degraded_sources ||= []
    @degraded_sources << message.to_s
    @logger&.warn("[authority] #{message}")
  end

  def wikidata_ids_linked_from(title)
    titles = wikipedia_links(title)
    qids = []
    titles.each_slice(50) do |slice|
      response = get_json(
        "https://en.wikipedia.org/w/api.php",
        action: "query",
        prop: "pageprops",
        ppprop: "wikibase_item",
        redirects: "1",
        titles: slice.join("|"),
        format: "json",
        formatversion: "2"
      )
      Array(response.dig("query", "pages")).each do |page|
        qid = page.dig("pageprops", "wikibase_item").to_s
        qids << qid if qid.match?(/\AQ\d+\z/)
      end
    end
    qids.uniq
  end

  def wikipedia_links(title)
    links = []
    continuation = nil
    loop do
      params = {
        action: "query",
        prop: "links",
        plnamespace: "0",
        pllimit: "max",
        titles: title,
        format: "json",
        formatversion: "2"
      }
      params[:plcontinue] = continuation if continuation
      response = get_json("https://en.wikipedia.org/w/api.php", params)
      page = Array(response.dig("query", "pages")).first || {}
      links.concat(Array(page["links"]).map { |link| link["title"].to_s }.reject(&:empty?))
      continuation = response.dig("continue", "plcontinue")
      break unless continuation
    end
    links.uniq
  end

  def fetch_entities(ids)
    wanted = Array(ids).map(&:to_s).select { |id| id.match?(/\AQ\d+\z/) }.uniq
    missing = wanted.reject { |id| @entity_cache.key?(id) }
    missing.each_slice(50) do |slice|
      response = get_json(
        "https://www.wikidata.org/w/api.php",
        action: "wbgetentities",
        ids: slice.join("|"),
        props: "labels|aliases|descriptions|claims|sitelinks",
        languages: "en|zh|zh-hant|ja|ko|vi",
        languagefallback: "1",
        format: "json"
      )
      response.fetch("entities", {}).each { |qid, entity| @entity_cache[qid] = entity }
      sleep(0.03)
    end
    wanted.filter_map { |qid| [qid, @entity_cache[qid]] if @entity_cache.key?(qid) }.to_h
  end

  def build_rulers(country, entities)
    humans = entities.values.select { |entity| human?(entity) }
    position_ids = humans.flat_map { |entity| item_claim_ids(entity, "P39") }.uniq
    position_entities = fetch_entities(position_ids)
    position_labels = position_entities.transform_values { |entity| label_for(entity, "en") }

    humans.filter_map do |entity|
      positions = item_claim_ids(entity, "P39").filter_map { |qid| position_labels[qid] }
      next unless ruler_entity?(entity, positions)

      start_date, end_date = reign_dates(entity, position_labels)
      {
        "qid" => entity.fetch("id"),
        "source" => "wikidata_east_asia",
        "country" => country,
        "label" => preferred_label(entity, country),
        "local_label" => local_label(entity, country),
        "han_names" => han_names(entity),
        "readings" => reading_names(entity),
        "reign_start_date" => start_date,
        "reign_end_date" => end_date,
        "reign_start_year" => year_from_wikidata_time(start_date),
        "reign_end_year" => year_from_wikidata_time(end_date),
        "positions" => positions,
        "source_url" => "https://www.wikidata.org/wiki/#{entity.fetch('id')}",
        "provenance" => ["Wikidata CC0"]
      }.compact
    end
  end

  def build_eras(country, entities)
    class_ids = entities.values.flat_map { |entity| item_claim_ids(entity, "P31") }.uniq
    class_entities = fetch_entities(class_ids)
    class_labels = class_entities.transform_values { |entity| label_for(entity, "en") }

    polity_ids = entities.values.flat_map { |entity| item_claim_ids(entity, "P17") }.uniq
    polity_entities = fetch_entities(polity_ids)
    polity_labels = polity_entities.transform_values { |entity| preferred_label(entity, country) }

    entities.values.filter_map do |entity|
      classes = item_claim_ids(entity, "P31").filter_map { |qid| class_labels[qid] }
      next unless era_entity?(entity, classes)

      start_date = first_time_claim(entity, "P580") || first_time_claim(entity, "P571")
      end_date = first_time_claim(entity, "P582")
      creator_ids = item_claim_ids(entity, "P170")
      polity_qids = item_claim_ids(entity, "P17")
      polities = polity_qids.filter_map { |qid| polity_labels[qid] }
      description = label_value(entity["descriptions"], "en")
      next if foreign_era_entity?(country, description, polities)
      {
        "qid" => entity.fetch("id"),
        "source" => "wikidata_east_asia",
        "country" => country,
        "label" => preferred_label(entity, country),
        "local_label" => local_label(entity, country),
        "han_names" => han_names(entity),
        "readings" => reading_names(entity),
        "start_date" => start_date,
        "end_date" => end_date,
        "start_year" => year_from_wikidata_time(start_date),
        "end_year" => year_from_wikidata_time(end_date),
        "ruler_qids" => creator_ids,
        "polity_qids" => polity_qids,
        "polities" => polities,
        "origin_country" => country,
        "adopted_from_foreign" => false,
        "source_url" => "https://www.wikidata.org/wiki/#{entity.fetch('id')}",
        "provenance" => ["Wikidata CC0"]
      }.compact
    end
  end

  def foreign_era_entity?(expected_country, description, polities)
    text = description.to_s
    local_adjectives = {
      "Japan" => /Japanese era/i,
      "Korea" => /Korean era/i,
      "Vietnam" => /Vietnamese era/i
    }
    return false if local_adjectives[expected_country]&.match?(text)

    foreign_adjectives = {
      "Japan" => [/Chinese era/i, /Korean era/i, /Vietnamese era/i],
      "Korea" => [/Chinese era/i, /Japanese era/i, /Vietnamese era/i],
      "Vietnam" => [/Chinese era/i, /Japanese era/i, /Korean era/i]
    }
    return true if Array(foreign_adjectives[expected_country]).any? { |pattern| text.match?(pattern) }

    # The list parser deliberately creates a local-use relationship for an
    # adopted foreign era. Do not relabel the foreign Wikidata authority itself
    # as Korean/Japanese/Vietnamese merely because the list linked to it.
    polity_text = Array(polities).join(" ")
    case expected_country
    when "Japan" then polity_text.match?(/China|Korea|Vietnam|中國|朝鮮|越南/i)
    when "Korea" then polity_text.match?(/China|Japan|Vietnam|中國|日本|越南/i)
    when "Vietnam" then polity_text.match?(/China|Japan|Korea|中國|日本|朝鮮/i)
    else false
    end
  end

  def local_reading_from_cell(cell)
    fragments = cell.xpath(".//text()").map { |node| normalize_space(node.text) }.reject(&:empty?)
    fragments.find { |fragment| fragment.match?(/[A-Za-zÀ-ỹĀ-ž]/) && !fragment.match?(/\A\d/) }
  end

  def enwiki_title_map(entities)
    entities.each_with_object({}) do |(qid, entity), output|
      title = entity.dig("sitelinks", "enwiki", "title").to_s
      output[title] = qid unless title.empty?
    end
  end

  def wikipedia_ruler_rows(page_title, ruler_title_map, country:)
    html = wikipedia_page_html(page_title)
    parse_wikipedia_ruler_html(
      html,
      page_title: page_title,
      ruler_title_map: ruler_title_map,
      country: country
    )
  end

  def parse_wikipedia_ruler_html(html, page_title:, ruler_title_map:, country:)
    require "nokogiri"

    document = Nokogiri::HTML.fragment(html.to_s)
    source_url = "https://en.wikipedia.org/wiki/#{page_title.tr(' ', '_')}"
    output = {}

    document.css("table").each do |table|
      headers = ruler_table_headers(table)
      section_labels = section_context_labels(table)
      next if headers.empty?

      name_columns = headers.each_index.select { |index| ruler_name_column?(headers[index]) }
      reign_columns = headers.each_index.select { |index| ruler_reign_column?(headers[index]) }
      next if name_columns.empty?

      table.css("tr").each do |tr|
        cells = expanded_row_cells(tr)
        next if cells.empty?

        linked_name_columns = cells.each_index.select do |index|
          cell = cells[index]
          next false unless cell
          next false unless wikipedia_link_title(cell)

          header = headers[index].to_s
          !header.match?(/reign|period|life|portrait|image|era name|年號/i)
        end
        harvest_columns = (name_columns + linked_name_columns).uniq
        names = harvest_columns.flat_map do |index|
          cell = cells[index]
          cell ? extract_han_names(cell.text) : []
        end.uniq
        next if names.empty?

        reign_text = reign_columns.filter_map { |index| cells[index]&.text }.join(" ")
        reign_start, reign_end = parse_historical_year_period(reign_text)

        linked_titles = harvest_columns.filter_map { |index| wikipedia_link_title(cells[index]) }.uniq
        mapped = linked_titles.filter_map { |title| ruler_title_map[title] }.uniq
        mapped = tr.css("a").filter_map { |link| ruler_title_map[wikipedia_link_title(link)] }.uniq if mapped.empty?
        next if mapped.length > 1

        qid = mapped.first || synthetic_ruler_id(
          country: country,
          linked_title: linked_titles.first,
          names: names,
          reign_start: reign_start,
          reign_end: reign_end
        )
        row = output[qid] ||= {
          "qid" => qid,
          "han_names" => Set.new,
          "polities" => Set.new,
          "provenance" => Set.new,
          "source_url" => source_url
        }
        names.each { |name| row["han_names"] << name }
        section_labels.each { |label| row["polities"] << label }
        row["reign_start_year"] ||= reign_start
        row["reign_end_year"] ||= reign_end
        chronology_confidence = ruler_chronology_confidence(tr.text)
        if chronology_confidence
          row["chronology_confidence"] = chronology_confidence
          row["chronology_note"] ||= "Wikipedia's ruler list explicitly flags this chronology as legendary, disputed, or traditional."
        end
        row["provenance"] << "Wikipedia ruler list (CC BY-SA 4.0)"
      end
    end

    output.transform_values do |row|
      row.merge(
        "han_names" => row.fetch("han_names").to_a,
        "polities" => row.fetch("polities").to_a,
        "provenance" => row.fetch("provenance").to_a
      )
    end
  end

  def synthetic_ruler_id(country:, linked_title:, names:, reign_start:, reign_end:)
    key = [country, linked_title, Array(names).sort.join("|"), reign_start, reign_end].join("\0")
    token = Digest::SHA256.hexdigest(key)[0, 18]
    "WP-RULER-#{country}-#{token}"
  end

  def ruler_table_headers(table)
    # Wikipedia monarch tables frequently use two header rows with colspan
    # subdivisions such as “Personal name” → “Westernized / Hangul-Hanja”.
    # Build a lightweight column grid so the data cells still inherit the broad
    # semantic heading from the first row.
    header_rows = table.xpath("./thead/tr|./tbody/tr|./tr").take_while do |tr|
      tr.xpath("./td").empty? && tr.xpath("./th").any?
    end
    return [] if header_rows.empty?

    grid = []
    occupied_until = Hash.new(0)
    header_rows.each_with_index do |tr, row_index|
      col = 0
      tr.xpath("./th").each do |cell|
        col += 1 while occupied_until[col] > row_index
        colspan = [cell["colspan"].to_i, 1].max
        rowspan = [cell["rowspan"].to_i, 1].max
        text = normalize_space(cell.text)
        colspan.times do |offset|
          idx = col + offset
          grid[idx] ||= []
          grid[idx] << text unless text.empty?
          occupied_until[idx] = [occupied_until[idx], row_index + rowspan].max
        end
        col += colspan
      end
    end
    grid.map { |parts| Array(parts).uniq.join(" / ") }
  end

  def expanded_row_cells(tr)
    cells = []
    tr.xpath("./th|./td").each do |cell|
      colspan = [cell["colspan"].to_i, 1].max
      colspan.times { cells << cell }
    end
    cells
  end

  def ruler_chronology_confidence(row_text)
    text = normalize_space(row_text)
    return "traditional_or_legendary" if text.match?(/presumed legendary|semi[- ]legendary|legendary ruler|traditional dates?|traditional chronology|historicity (?:is )?disputed|historicity uncertain|not historically verified/i)

    nil
  end

  def ruler_name_column?(header)
    text = header.to_s
    return false if text.match?(/era name|年號|reign|period|life|portrait|image|dynasty|house|no\.?\b|number/i)

    text.match?(/personal name|posthumous name|temple name|courtesy name|pseudonym|full name|regnal name|emperor|monarch|king|name\b/i)
  end

  def ruler_reign_column?(header)
    header.to_s.match?(/period of reign|\breign\b/i) && !header.to_s.match?(/era name/i)
  end

  def enrich_rulers_from_ruler_list!(rulers, rows_by_qid, country:)
    by_qid = rulers.index_by { |row| row["qid"].to_s }

    rows_by_qid.each do |qid, row|
      ruler = by_qid[qid.to_s]
      unless ruler
        # The canonical ruler list is itself strong discovery evidence. Some
        # legendary/early monarchs or sparsely modelled rulers are not P31=human
        # or do not have a usable P39 statement in Wikidata; do not silently lose
        # them after successfully identifying their list row and Wikidata item.
        entity = @entity_cache[qid.to_s]
        entity_names = entity ? han_names(entity) : []
        entity_readings = entity ? reading_names(entity) : []
        ruler = {
          "qid" => qid.to_s,
          "source" => entity ? "wikidata_east_asia+wikipedia_ruler_list" : "wikipedia_ruler_list",
          "country" => country,
          "label" => entity ? preferred_label(entity, country) : Array(row["han_names"]).first,
          "local_label" => entity ? local_label(entity, country) : nil,
          "han_names" => (entity_names + Array(row["han_names"])).uniq,
          "readings" => entity_readings,
          "reign_start_year" => row["reign_start_year"],
          "reign_end_year" => row["reign_end_year"],
          "positions" => [],
          "polities" => Array(row["polities"]),
          "chronology_confidence" => row["chronology_confidence"],
          "chronology_note" => row["chronology_note"],
          "source_url" => entity ? "https://www.wikidata.org/wiki/#{qid}" : row["source_url"],
          "provenance" => (Array(row["provenance"]) + (entity ? ["Wikidata CC0"] : [])).uniq
        }.compact
        rulers << ruler
        by_qid[qid.to_s] = ruler
        next
      end

      names = Array(row["han_names"])
      ruler["han_names"] = (Array(ruler["han_names"]) + names).uniq
      if ruler["reign_start_year"].nil? && row["reign_start_year"]
        ruler["reign_start_year"] = row["reign_start_year"]
      elsif ruler["reign_start_year"] && row["reign_start_year"] && ruler["reign_start_year"] != row["reign_start_year"]
        ruler["reign_date_conflict"] ||= {}
        ruler["reign_date_conflict"]["wikipedia_start_year"] = row["reign_start_year"]
      end
      if ruler["reign_end_year"].nil? && row["reign_end_year"]
        ruler["reign_end_year"] = row["reign_end_year"]
      elsif ruler["reign_end_year"] && row["reign_end_year"] && ruler["reign_end_year"] != row["reign_end_year"]
        ruler["reign_date_conflict"] ||= {}
        ruler["reign_date_conflict"]["wikipedia_end_year"] = row["reign_end_year"]
      end
      ruler["polities"] = (Array(ruler["polities"]) + Array(row["polities"])).uniq
      ruler["chronology_confidence"] ||= row["chronology_confidence"]
      ruler["chronology_note"] ||= row["chronology_note"]
      ruler["provenance"] = (Array(ruler["provenance"]) + Array(row["provenance"])).uniq
    end
  end

  def wikipedia_era_rows(page_title, country:, ruler_title_map:, era_title_map:)
    html = wikipedia_page_html(page_title)
    parse_wikipedia_era_html(
      html,
      page_title: page_title,
      country: country,
      ruler_title_map: ruler_title_map,
      era_title_map: era_title_map
    )
  end

  def wikipedia_page_html(page_title)
    response = get_json(
      "https://en.wikipedia.org/w/api.php",
      action: "parse",
      page: page_title,
      prop: "text",
      format: "json",
      formatversion: "2"
    )
    html = response.dig("parse", "text").to_s
    raise "Wikipedia parse API returned an empty page for #{page_title}" if html.empty?

    html
  rescue StandardError => api_error
    note_degraded_source!("#{page_title}: MediaWiki API unavailable; using ordinary article HTML (#{api_error.class}: #{api_error.message})")
    get_text("https://en.wikipedia.org/wiki/#{page_title.tr(' ', '_')}")
  end

  def parse_wikipedia_era_html(html, page_title:, country:, ruler_title_map:, era_title_map:)
    require "nokogiri"

    document = Nokogiri::HTML.fragment(html.to_s)
    source_url = "https://en.wikipedia.org/wiki/#{page_title.tr(' ', '_')}"
    rows = []

    document.css("table.wikitable").each do |table|
      next unless era_table?(table)

      section_labels = section_context_labels(table)
      current_ruler = nil
      table.css("tr").each do |tr|
        cells = tr.xpath("./th|./td")
        next if cells.empty?

      # A ruler cell is normally row-spanned across all of that ruler's era
      # rows. Capture it whenever it appears and carry it over to following rows.
      ruler_cell = cells.find { |cell| cell.text.match?(/\(\s*r\.\s*\d/i) }
      if ruler_cell
        ruler_title = wikipedia_link_title(ruler_cell)
        reign_start, reign_end = parse_year_period(ruler_cell.text, require_reign_marker: true)
        ruler_han_names = extract_han_names(ruler_cell.text)
        current_ruler = {
          "qid" => (ruler_title && ruler_title_map[ruler_title]) || synthetic_ruler_id(
            country: country,
            linked_title: ruler_title,
            names: ruler_han_names,
            reign_start: reign_start,
            reign_end: reign_end
          ),
          "title" => ruler_title,
          "han_names" => ruler_han_names,
          "polities" => section_labels,
          "reign_start_year" => reign_start,
          "reign_end_year" => reign_end
        }.compact
      end

      period_index = cells.index do |cell|
        text = normalize_space(cell.text)
        !text.match?(/\(\s*r\./i) && (text.match?(/\b\d{2,4}\s*(?:CE)?(?:\s*[–—-]\s*(?:\d{2,4}|\?))?/i) || text.match?(/\bUnknown\b/i) || text.match?(/did not use/i))
      end
      next unless period_index && period_index.positive?

      era_cell = cells[period_index - 1]
      era_text = normalize_space(era_cell.text)
      han = extract_han_names(era_text).select { |name| name.each_char.count <= 8 }
      next if han.empty?
      reading = local_reading_from_cell(era_cell)

      start_year, end_year = parse_year_period(cells[period_index].text)
      remark = cells[(period_index + 1)..].to_a.map { |cell| normalize_space(cell.text) }.reject(&:empty?).join(" | ")
      han = (han + alternative_han_names_from_remark(remark)).uniq
      origin_country = foreign_era_origin(country, remark, section_labels: section_labels)
      adopted_from_foreign = origin_country != country
      epoch_start_year = explicit_era_epoch_start(remark)
      era_title = wikipedia_link_title(era_cell)
      qid = adopted_from_foreign ? nil : (era_title && era_title_map[era_title])
      ruler_qids = Set.new
      ruler_qids << current_ruler["qid"] if current_ruler && current_ruler["qid"]
      tr.css("a").each do |link|
        title = link["title"].to_s
        mapped = ruler_title_map[title]
        ruler_qids << mapped if mapped
      end

      synthetic = Digest::SHA256.hexdigest([
        country, han.first, start_year, end_year, current_ruler.to_h["qid"], remark
      ].join("\0"))[0, 18]
      rows << {
        "qid" => qid || "WP-#{country}-#{synthetic}",
        "source" => qid ? "wikidata_east_asia+wikipedia_era_list" : "wikipedia_era_list",
        "country" => country,
        "label" => reading.presence || han.first,
        "local_label" => reading.presence,
        "han_names" => han,
        "readings" => [reading].compact,
        "start_year" => adopted_from_foreign ? nil : start_year,
        "end_year" => adopted_from_foreign ? nil : end_year,
        "epoch_start_year" => epoch_start_year,
        "local_use_start_year" => start_year,
        "local_use_end_year" => end_year,
        "origin_country" => origin_country,
        "adopted_from_foreign" => adopted_from_foreign,
        "polities" => section_labels,
        "ruler_qids" => ruler_qids.to_a,
        "list_ruler" => current_ruler,
        "source_url" => source_url,
        "source_note" => remark.presence,
        "provenance" => ["Wikipedia era list (CC BY-SA 4.0)"]
      }.compact
      end
    end
    rows
  end

  def enrich_rulers_from_list!(rulers, list_rows)
    by_qid = rulers.index_by { |row| row["qid"].to_s }
    list_rows.each do |era|
      list_ruler = era["list_ruler"]
      next unless list_ruler.is_a?(Hash) && list_ruler["qid"].present?
      ruler = by_qid[list_ruler["qid"].to_s]
      next unless ruler

      ruler["han_names"] = (Array(ruler["han_names"]) + Array(list_ruler["han_names"])).uniq
      ruler["polities"] = (Array(ruler["polities"]) + Array(list_ruler["polities"])).uniq
      if ruler["reign_start_year"].nil? && list_ruler["reign_start_year"]
        ruler["reign_start_year"] = list_ruler["reign_start_year"]
      end
      if ruler["reign_end_year"].nil? && list_ruler["reign_end_year"]
        ruler["reign_end_year"] = list_ruler["reign_end_year"]
      end
      ruler["provenance"] = (Array(ruler["provenance"]) + ["Wikipedia era list (CC BY-SA 4.0)"]).uniq
    end
  end

  def merge_era_list_rows!(eras, list_rows)
    by_qid = eras.index_by { |row| row["qid"].to_s }
    list_rows.each do |list_row|
      existing = by_qid[list_row["qid"].to_s]
      unless existing
        # If the list entry itself has no Wikidata item, only merge on the same
        # country + Han name when the intervals overlap. Reused era names remain
        # separate authorities.
        existing = eras.find do |row|
          next false unless row["country"] == list_row["country"]
          next false if (Array(row["han_names"]) & Array(list_row["han_names"])).empty?
          row_polities = Array(row["polities"])
          list_polities = Array(list_row["polities"])
          next false if row_polities.any? && list_polities.any? && (row_polities & list_polities).empty?

          intervals_overlap?(row["start_year"], row["end_year"], list_row["start_year"], list_row["end_year"])
        end
      end

      if existing
        existing["han_names"] = (Array(existing["han_names"]) + Array(list_row["han_names"])).uniq
        existing["readings"] = (Array(existing["readings"]) + Array(list_row["readings"])).uniq
        existing["ruler_qids"] = (Array(existing["ruler_qids"]) + Array(list_row["ruler_qids"])).uniq
        existing["polities"] = (Array(existing["polities"]) + Array(list_row["polities"])).uniq
        existing["provenance"] = (Array(existing["provenance"]) + Array(list_row["provenance"])).uniq
        existing["local_use_start_year"] ||= list_row["local_use_start_year"]
        existing["local_use_end_year"] ||= list_row["local_use_end_year"]
        existing["epoch_start_year"] ||= list_row["epoch_start_year"]
        existing["origin_country"] ||= list_row["origin_country"]
        existing["adopted_from_foreign"] ||= list_row["adopted_from_foreign"]
        existing["source_note"] ||= list_row["source_note"]
        if existing["start_year"].nil? && !list_row["adopted_from_foreign"]
          existing["start_year"] = list_row["start_year"]
          existing["end_year"] = list_row["end_year"]
        elsif !list_row["adopted_from_foreign"] && existing["start_year"] && list_row["start_year"] && existing["start_year"] != list_row["start_year"]
          existing["date_conflict"] = {
            "wikidata_start_year" => existing["start_year"],
            "wikipedia_start_year" => list_row["start_year"],
            "wikipedia_end_year" => list_row["end_year"]
          }
        end
      else
        clean = list_row.except("list_ruler")
        eras << clean
        by_qid[clean["qid"].to_s] = clean
      end
    end
  end

  def era_table?(table)
    # Production era tables identify both the era-name and use-period columns.
    # Tests and a few legacy MediaWiki renderings can omit TH elements, so only
    # enforce this semantic guard when a real header row is present.
    headers = normalize_space(table.css("th").map(&:text).join(" "))
    return true if headers.empty?

    headers.match?(/era name/i) && headers.match?(/period of use/i)
  end

  def section_context_labels(node)
    labels = %w[h2 h3 h4].filter_map do |tag|
      heading = node.xpath("preceding::#{tag}[1]").first
      next unless heading

      text = normalize_space(heading.text).sub(/\[edit\]\z/i, "").strip
      text unless text.empty? || text.match?(/\A(?:List of .* era names|Modern era systems)\z/i)
    end
    labels.uniq
  end

  def alternative_han_names_from_remark(remark)
    text = normalize_space(remark)
    clauses = text.split(/[.;|]/).select do |clause|
      clause.match?(/\b(?:or|also known as|also called|alternative(?:ly)?|variant)\b/i)
    end
    names = clauses.flat_map { |clause| extract_han_names(clause) }

    # The Korean era table writes the abbreviated Dangun calendar as
    # “Dangi (단기; 檀紀)” rather than using an “also known as” formula.
    text.scan(/\bDangi\s*\([^)]*(\p{Han}{2,8})[^)]*\)/i) { |match| names << match.first }
    names.select { |name| name.each_char.count <= 8 }.uniq
  end

  def intervals_overlap?(left_start, left_end, right_start, right_end)
    return false unless left_start && right_start
    left_end ||= left_start
    right_end ||= right_start
    left_start <= right_end && right_start <= left_end
  end

  def linked_title_in(node, mapping)
    node.css("a").each do |link|
      title = wikipedia_link_title(link)
      return title if title && mapping.key?(title)
    end
    nil
  end

  def wikipedia_link_title(node)
    link = node.name == "a" ? node : node.css("a").first
    return nil unless link

    title = link["title"].to_s.strip
    return title unless title.empty?

    href = link["href"].to_s
    match = href.match(%r{(?:\Ahttps?://en\.wikipedia\.org)?/wiki/([^#?]+)})
    return nil unless match

    URI.decode_www_form_component(match[1].tr("_", " "))
  rescue ArgumentError
    nil
  end

  def foreign_era_origin(country, remark, section_labels: [])
    text = normalize_space(remark)
    section_text = Array(section_labels).map(&:to_s).join(" ")
    return "China" if text.match?(/(?:adopted|used).*?(?:era name|reign title).*?(?:China|Chinese|Ming|Qing|Tang|Song|Yuan)/i)

    if country == "Korea"
      return "Japan" if section_text.match?(/Korea under Japanese rule|Japanese rule/i)
      return "Japan" if text.match?(/\b(?:Japan|Japanese)\b/i)
    end

    country
  end

  def explicit_era_epoch_start(remark)
    text = normalize_space(remark)
    # 西曆紀元 is explicitly the Common Era: 1 CE is year one even though the
    # designation was only adopted in South Korea from 1962. Keep epoch and
    # local-use interval separate just as with 開國 and 檀君紀元.
    return 1 if text.match?(/(?:Common Era|Anno Domini)/i)

    patterns = [
      /(?:1st|first) year(?: of [^.;|]+)?[^.;|]*?(?:taken|regarded|designated|reckoned)[^.;|]*?(?:to be|as)\s*(\d{1,4})\s*(BC|BCE|AD|CE)/i,
      /(?:1st|first) year.*?(\d{1,4})\s*(BC|BCE|AD|CE)/i,
      /(\d{1,4})\s*(BC|BCE|AD|CE).*?(?:designated|regarded|taken|reckoned).*?(?:first year|year one)/i,
      /(?:from|foundation.*?in)\s*(\d{1,4})\s*(BC|BCE|AD|CE).*?(?:first year|year one)/i
    ]
    patterns.each do |pattern|
      match = text.match(pattern)
      next unless match
      return signed_historical_year(match[1], match[2])
    end
    nil
  end

  def parse_year_period(value, require_reign_marker: false)
    text = normalize_space(value)
    return [nil, nil] if require_reign_marker && !text.match?(/\br\./i)
    return [nil, nil] if text.match?(/Unknown|did not use/i)

    parse_historical_year_period(text)
  end

  def parse_historical_year_period(value)
    text = normalize_space(value)
    return [nil, nil] if text.empty? || text.match?(/Unknown|did not use/i)

    # Normalise common Wikipedia forms: “660–585 BC”, “645–654 CE”,
    # “2019 CE–present”, “1883”, and “fl. 270”. A trailing BC/BCE applies to
    # both members of an unqualified range.
    text = text.gsub(/[−‐‑‒–—]/, "-")
    range = text.match(/(?:c\.?\s*)?(\d{1,4})\s*(BC|BCE|AD|CE)?\s*-\s*(?:(?:c\.?\s*)?(\d{1,4})\s*(BC|BCE|AD|CE)?|present)/i)
    if range
      trailing_era = range[4].to_s.upcase.presence || range[2].to_s.upcase.presence
      start_year = signed_historical_year(range[1], range[2].presence || trailing_era)
      if text.match?(/-\s*present/i)
        end_year = Time.now.utc.year
      else
        end_year = signed_historical_year(range[3], range[4].presence || trailing_era)
      end
      return [start_year, end_year]
    end

    single = text.match(/(?:fl\.?|c\.?)?\s*(\d{1,4})\s*(BC|BCE|AD|CE)?/i)
    return [nil, nil] unless single

    year = signed_historical_year(single[1], single[2])
    [year, year]
  end

  def signed_historical_year(number, era)
    return nil if number.to_s.empty?
    year = number.to_i
    era.to_s.upcase.match?(/\ABC|BCE\z/) ? -year : year
  end

  def normalize_space(value)
    value.to_s.gsub(/\s+/, " ").strip
  end

  def infer_era_rulers!(eras, rulers)
    rulers_by_country = rulers.group_by { |row| row.fetch("country") }
    valid_ruler_ids = rulers.map { |row| row.fetch("qid").to_s }.to_set
    eras.each do |era|
      # Era pages can link rulers that are not part of the canonical ruler list
      # (comparative examples, foreign sovereigns, notes). Do not leave dangling
      # era_rulers pointers after canonical discovery scoping.
      ids = Set.new(Array(era["ruler_qids"]).map(&:to_s).select { |qid| valid_ruler_ids.include?(qid) })
      if era["start_year"] && era["end_year"]
        Array(rulers_by_country[era["country"]]).each do |ruler|
          next unless ruler["reign_start_year"] && ruler["reign_end_year"]
          next if ruler["reign_end_year"] < era["start_year"]
          next if ruler["reign_start_year"] > era["end_year"]

          ids << ruler.fetch("qid")
        end
      end
      era["ruler_qids"] = ids.to_a.sort
    end
  end

  def ruler_entity?(entity, position_labels)
    description = label_value(entity["descriptions"], "en")
    return false if description.match?(/\bconsort\b/i)
    return true if description.match?(RULER_DESCRIPTION)
    return true if position_labels.any? { |label| label.to_s.match?(RULER_POSITION) && !label.to_s.match?(/consort/i) }

    item_claim_ids(entity, "P106").include?("Q116")
  end

  def era_entity?(entity, class_labels)
    description = label_value(entity["descriptions"], "en")
    class_labels.any? { |label| label.to_s.downcase.include?("era name") } || description.match?(ERA_DESCRIPTION)
  end

  def human?(entity)
    item_claim_ids(entity, "P31").include?("Q5")
  end

  def reign_dates(entity, position_labels)
    statements = Array(entity.dig("claims", "P39"))
    ruler_statements = statements.select do |statement|
      qid = statement.dig("mainsnak", "datavalue", "value", "id").to_s
      position_labels[qid].to_s.match?(RULER_POSITION)
    end
    ruler_statements = statements if ruler_statements.empty? && label_value(entity["descriptions"], "en").match?(RULER_DESCRIPTION)

    starts = ruler_statements.filter_map { |statement| qualifier_time(statement, "P580") }
    ends = ruler_statements.filter_map { |statement| qualifier_time(statement, "P582") }
    [starts.min_by { |value| sortable_time(value) }, ends.max_by { |value| sortable_time(value) }]
  end

  def han_names(entity)
    values = []
    %w[zh zh-hant ja ko vi].each do |language|
      values << label_value(entity["labels"], language)
      values.concat(Array(entity.dig("aliases", language)).map { |row| row["value"].to_s })
    end
    %w[zhwiki jawiki kowiki viwiki].each do |site|
      values << entity.dig("sitelinks", site, "title").to_s
    end
    NAME_PROPERTIES.each do |property|
      Array(entity.dig("claims", property)).each do |statement|
        values << scalar_claim_value(statement)
      end
    end

    values.compact.flat_map { |value| extract_han_names(value) }.uniq
  end

  def reading_names(entity)
    values = []
    %w[en ja ko vi].each do |language|
      values << label_value(entity["labels"], language)
      values.concat(Array(entity.dig("aliases", language)).map { |row| row["value"].to_s })
    end
    READING_PROPERTIES.each do |property|
      Array(entity.dig("claims", property)).each { |statement| values << scalar_claim_value(statement) }
    end
    values.map(&:to_s).map(&:strip).reject(&:empty?).uniq.first(40)
  end

  def extract_han_names(value)
    text = value.to_s.strip
    return [] if text.empty?

    output = text.scan(/\p{Han}{2,16}/)
    compact = text.gsub(/[\s·・.()（）\[\]【】]/, "")
    output << compact if compact.match?(/\A\p{Han}{2,16}\z/)
    output.reject { |name| %w[天皇 皇帝 皇后 國王 国王 王后 太王 大王].include?(name) }.uniq
  end

  def preferred_label(entity, country)
    language = { "Japan" => "ja", "Korea" => "ko", "Vietnam" => "vi" }.fetch(country)
    label_for(entity, language).presence || label_for(entity, "zh").presence || label_for(entity, "en")
  end

  def local_label(entity, country)
    language = { "Japan" => "ja", "Korea" => "ko", "Vietnam" => "vi" }.fetch(country)
    label_for(entity, language).presence
  end

  def label_for(entity, language)
    label_value(entity["labels"], language)
  end

  def label_value(hash, language)
    hash.to_h.dig(language, "value").to_s
  end

  def item_claim_ids(entity, property)
    Array(entity.dig("claims", property)).filter_map do |statement|
      value = statement.dig("mainsnak", "datavalue", "value")
      value.is_a?(Hash) ? value["id"].to_s.presence : nil
    end
  end

  def scalar_claim_value(statement)
    value = statement.dig("mainsnak", "datavalue", "value")
    case value
    when String then value
    when Hash then value["text"].to_s.presence || value["id"].to_s.presence
    end
  end

  def first_time_claim(entity, property)
    Array(entity.dig("claims", property)).filter_map do |statement|
      wikidata_time(statement.dig("mainsnak", "datavalue", "value"))
    end.min_by { |value| sortable_time(value) }
  end

  def qualifier_time(statement, property)
    Array(statement.dig("qualifiers", property)).filter_map do |snak|
      wikidata_time(snak.dig("datavalue", "value"))
    end.first
  end

  def wikidata_time(value)
    return nil unless value.is_a?(Hash)

    value["time"].to_s.presence
  end

  def year_from_wikidata_time(value)
    match = value.to_s.match(/\A([+-])(\d+)-/)
    return nil unless match

    year = match[2].to_i
    match[1] == "-" ? -year : year
  end

  def sortable_time(value)
    year_from_wikidata_time(value) || 99_999
  end

  def get_json(url, params = nil, limit: 5, **keyword_params)
    # Ruby 3 no longer folds keyword arguments into a trailing Hash. Most API
    # callers use the readable get_json(url, action: ..., format: ...) form,
    # while continuation calls pass an already-built positional params hash.
    # Accept both forms explicitly so a language-level argument error cannot be
    # misreported as a degraded Wikimedia source.
    query_params = (params || {}).to_h.merge(keyword_params)
    uri = URI(url)
    uri.query = URI.encode_www_form(query_params)
    attempts = 0

    loop do
      attempts += 1
      begin
        response = request(uri, limit: limit, accept: "application/json")
        unless response.is_a?(Net::HTTPSuccess)
          retryable = response.code.to_i == 429 || response.code.to_i >= 500
          if retryable && attempts < 4
            retry_after = response["Retry-After"].to_i
            sleep(retry_after.positive? ? [retry_after, 30].min : 0.75 * attempts)
            next
          end
          raise "HTTP #{response.code} from #{uri.host}: #{response.body.to_s[0, 200]}"
        end
        return JSON.parse(response.body)
      rescue JSON::ParserError, IOError, SystemCallError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError
        raise if attempts >= 4

        sleep(0.75 * attempts)
      end
    end
  end

  def get_text(url, limit: 5)
    uri = URI(url)
    attempts = 0
    loop do
      attempts += 1
      begin
        response = request(uri, limit: limit, accept: "text/html,application/xhtml+xml")
        unless response.is_a?(Net::HTTPSuccess)
          retryable = response.code.to_i == 429 || response.code.to_i >= 500
          if retryable && attempts < 4
            retry_after = response["Retry-After"].to_i
            sleep(retry_after.positive? ? [retry_after, 30].min : 0.75 * attempts)
            next
          end
          raise "HTTP #{response.code} from #{uri.host}: #{response.body.to_s[0, 200]}"
        end
        body = response.body.to_s
        raise "empty response from #{uri}" if body.empty?

        return body
      rescue IOError, SystemCallError, Timeout::Error, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError
        raise if attempts >= 4

        sleep(0.75 * attempts)
      end
    end
  end

  def request(uri, limit:, accept:)
    raise "too many redirects" if limit <= 0

    req = Net::HTTP::Get.new(uri)
    req["User-Agent"] = USER_AGENT
    req["Accept"] = accept
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 20, read_timeout: 60) do |http|
      http.request(req)
    end
    if response.is_a?(Net::HTTPRedirection)
      location = response["location"].to_s
      raise "redirect from #{uri} did not include a Location header" if location.empty?

      return request(URI.join(uri.to_s, location), limit: limit - 1, accept: accept)
    end
    response
  end
end
