# frozen_string_literal: true

# Automatic historical annotation uses the small authority orthography registry.
# It also treats the CBDB and supplementary historical indexes as independent
# sources: one malformed or temporarily unavailable source must not disable the
# other source for the whole reader.
module CbdbAutoAnnotatorStaticNames
  MAX_PREFIX_FORMS = 16
  SINGLE_CHARACTER_MAX_CANDIDATES = 6
  SINGLE_CHARACTER_CLUSTER_DISTANCE = 14
  SINGLE_CHARACTER_CLUSTER_MAX_OCCURRENCES = 4
  PERSON_SPEECH_FOLLOWERS = %w[曰 云 謂 谓 問 问 對 对 告 言 語 语 答 命 使 召].freeze
  PERSON_SPEECH_SYNTAX_BONUS = 18
  SINGLE_CHARACTER_FOLLOWERS = PERSON_SPEECH_FOLLOWERS
  SINGLE_CHARACTER_PRECEDERS = %w[爾 尔 命 召 呼 帝 唐 虞].freeze

  # Received high-antiquity figures are curated in data/three_sovereigns_five_emperors.xlsx.
  # They deliberately carry no invented birth/reign years.  The authority data
  # marks them with a broad chronology class, which gives the future-person gate
  # only a conservative upper bound before the Shang-period boundary.
  HIGH_ANTIQUITY_AUTHORITY_SOURCE = "fanya_high_antiquity"
  HIGH_ANTIQUITY_CHRONOLOGY_CONFIDENCE = "traditional_high_antiquity"
  HIGH_ANTIQUITY_SOURCE_PRIORITY = 5
  HIGH_ANTIQUITY_LATEST_YEAR = -1600

  PERIOD_RANGES = [
    [%w[東寧 东宁 明鄭 明郑 鄭氏 郑氏 東都 东都], 1661, 1683],
    [%w[太平天國餘部 太平天国余部 太平軍餘部 太平军余部], 1865, 1869],
    [%w[太平天國 太平天国], 1851, 1864],
    [%w[春秋 春秋時代 春秋时代], -770, -476],
    [%w[戰國 战国 戰國時代 战国时代], -475, -221],
    [%w[西周], -1046, -771],
    [%w[東周 东周], -770, -256],
    [%w[商朝 商], -1600, -1046],
    [%w[周朝 周], -1046, -256],
    [%w[先秦], -1600, -221],
    [%w[秦朝 秦], -221, -206],
    [%w[西漢 西汉], -206, 9],
    [%w[新朝 新], 9, 23],
    [%w[東漢 东汉], 25, 220],
    [%w[漢朝 汉朝 漢 汉], -206, 220],
    [%w[三國 三国], 220, 280],
    [%w[西晉 西晋], 266, 316],
    [%w[東晉 东晋], 317, 420],
    [%w[晉朝 晋朝 晉 晋], 266, 420],
    [%w[南北朝], 420, 589],
    [%w[隋朝 隋], 581, 618],
    [%w[唐朝 唐], 618, 907],
    [%w[五代十國 五代十国 五代], 907, 960],
    [%w[北宋], 960, 1127],
    [%w[南宋], 1127, 1279],
    [%w[宋朝 宋], 960, 1279],
    [%w[遼朝 辽朝 遼 辽], 916, 1125],
    [%w[金朝 女真金], 1115, 1234],
    [%w[西夏], 1038, 1227],
    [%w[元朝 元], 1271, 1368],
    [%w[明朝 明], 1368, 1644],
    [%w[清朝 清], 1644, 1912],
    [%w[中華民國 中华民国 民國 民国], 1912, 1949],
    [%w[中華人民共和國 中华人民共和国], 1949, 9999]
  ].freeze

  def initialize(text:, metadata:, store:)
    @text = text.to_s
    @chars = @text.each_char.to_a
    @metadata = metadata.to_h.stringify_keys
    @store = normalize_store(store)
    @equivalence = AuthorityHanVariantRegistry.instance
    @prefix_cache = {}
  end

  def call
    @context = temporal_context
    authority = safe_authority_metadata
    return CbdbAutoAnnotator::Result.new(items: [], context: @context, authority: authority) unless @store.available?

    matches = []
    one_character_candidates = Hash.new { |hash, key| hash[key] = [] }
    source_attempts = 0
    source_successes = 0
    failures = []

    @store.with_database do |db|
      @db = db
      prefixes = text_prefixes

      if @store.lookup_available?
        source_attempts += 1
        begin
          matches.concat(cbdb_matches(prefixes)) if prefixes.any?
          merge_single_character_candidates!(one_character_candidates, cbdb_single_character_candidates)
          source_successes += 1
        rescue StandardError => e
          failures << ["cbdb", e]
          log_source_failure("CBDB", e)
        end
      end

      if @store.historical_available?
        source_attempts += 1
        begin
          matches.concat(historical_matches(prefixes)) if prefixes.any?
          matches.concat(single_character_diviner_matches)
          merge_single_character_candidates!(one_character_candidates, historical_single_character_candidates)
          source_successes += 1
        rescue StandardError => e
          failures << ["historical", e]
          log_source_failure("historical", e)
        end
      end

      matches.concat(single_character_person_matches(one_character_candidates))
    ensure
      @db = nil
    end

    if source_attempts.positive? && source_successes.zero? && failures.any?
      raise failures.first.last
    end

    authority = safe_authority_metadata.merge(
      "annotation_partial" => failures.any?,
      "annotation_failed_sources" => failures.map(&:first)
    )
    CbdbAutoAnnotator::Result.new(
      items: resolve_overlaps(matches).map { |match| public_item(match) },
      context: @context,
      authority: authority
    )
  end

  private

  def cbdb_matches(prefixes)
    rows = fetch_pointer_rows("cbdb_lookup", prefixes)
    hydrated = []
    rows.group_by { |row| row["kind"].to_s }.each do |kind, kind_rows|
      begin
        hydrated.concat(hydrate_cbdb(kind_rows))
      rescue StandardError => e
        log_source_failure("CBDB #{kind}", e)
      end
    end
    build_multi_matches(hydrated)
  end

  # One-character historical names need stricter evidence than ordinary names.
  # Exact single graphs are collected from the authority indexes, but a graph is
  # ignored when it expands to too many authority records. This prevents common
  # graphs such as 子 from becoming automatic names merely because some authority
  # database happens to contain people or aliases written with that graph.
  def cbdb_single_character_candidates
    chars = one_character_text_chars
    return {} if chars.empty?

    rows = []
    chars.each_slice(CbdbAutoAnnotator::PREFIX_BATCH_SIZE) do |slice|
      placeholders = (["?"] * slice.length).join(",")
      rows.concat(@db.execute(<<~SQL, slice))
        SELECT prefix, name_length, name_chn, kind, entity_id, primary_name
        FROM cbdb_lookup.names
        WHERE name_length = 1 AND kind = 'person' AND name_chn IN (#{placeholders})
      SQL
    end

    rows.group_by { |row| row["name_chn"].to_s }.each_with_object({}) do |(name, name_rows), output|
      if authority_row_count(name_rows) > SINGLE_CHARACTER_MAX_CANDIDATES
        output[name] = :ambiguous
        next
      end

      candidates = hydrate_cbdb(name_rows).filter_map { |row| row["candidate"] }
      output[name] = specific_single_character_candidates(candidates)
    end
  end

  def historical_single_character_candidates
    chars = one_character_text_chars
    return {} if chars.empty?

    rows = []
    chars.each_slice(CbdbAutoAnnotator::PREFIX_BATCH_SIZE) do |slice|
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
        WHERE n.name_length = 1 AND n.name_chn IN (#{placeholders})
      SQL
    end

    rows.group_by { |row| row["name_chn"].to_s }.each_with_object({}) do |(name, name_rows), output|
      candidates = name_rows.filter_map { |row| historical_candidate(row) }
      if authority_row_count(name_rows) > SINGLE_CHARACTER_MAX_CANDIDATES
        curated = candidates.select { |candidate| high_antiquity_authority_candidate?(candidate) }
        output[name] = curated.any? ? specific_single_character_candidates(curated) : :ambiguous
        next
      end

      output[name] = specific_single_character_candidates(candidates)
    end
  end

  def one_character_text_chars
    @one_character_text_chars ||= @chars.select { |character| character.to_s.match?(/\p{Han}/) }.uniq
  end

  def authority_row_count(rows)
    Array(rows).map do |row|
      [row["source"].to_s.presence || "cbdb", row["entity_id"].to_s]
    end.uniq.length
  end

  def specific_single_character_candidates(candidates)
    values = Array(candidates)
      .compact
      .uniq { |candidate| [candidate[:authority_source], candidate[:id], candidate[:derivation]] }
      .sort_by { |candidate| candidate_sort_key(candidate) }
    return [] if values.empty? || values.length > SINGLE_CHARACTER_MAX_CANDIDATES

    values
  end

  def merge_single_character_candidates!(target, source)
    source.to_h.each do |name, candidates|
      if candidates == :ambiguous || target[name] == :ambiguous
        combined = [*Array(target[name]), *Array(candidates)]
        curated = combined.select { |candidate| high_antiquity_authority_candidate?(candidate) }
        if curated.any?
          target[name] = specific_single_character_candidates(curated)
        else
          target[name] = :ambiguous
        end
        next
      end

      combined = [*Array(target[name]), *Array(candidates)]
      merged = specific_single_character_candidates(combined)
      target[name] = combined.any? && merged.empty? ? :ambiguous : merged
    end
  end

  # A single graph is accepted when the text itself supplies name-like evidence:
  # a speech/address construction (堯曰, 爾舜, 命禹), or a close cluster of two
  # different, low-ambiguity one-character authority names. Once a graph is
  # accepted, repeated occurrences of the same graph are accepted too; this lets
  # an explicit first mention disambiguate a later short reference in the same
  # document. Nearby accepted names can then pull one further specific name into
  # the cluster, which covers sequences such as 堯 … 舜 … 舜 … 禹 without making
  # every one-character authority alias globally active.
  def single_character_person_matches(by_name)
    candidates_by_name = by_name.to_h.transform_values do |values|
      values == :ambiguous ? [] : specific_single_character_candidates(values)
    end
    candidates_by_name.delete_if { |_name, values| values.empty? }
    return [] if candidates_by_name.empty?

    occurrences = @chars.each_with_index.filter_map do |literal, index|
      candidates = candidates_by_name[literal]
      next unless candidates.present?

      {
        text: literal,
        start: index,
        end: index + 1,
        candidates: candidates,
        score: candidates.first.fetch(:score)
      }
    end
    return [] if occurrences.empty?

    counts = occurrences.group_by { |occurrence| occurrence[:text] }.transform_values(&:length)
    accepted_names = Set.new

    occurrences.each do |occurrence|
      accepted_names << occurrence[:text] if single_character_name_syntax?(occurrence[:start])
    end

    occurrences.each_with_index do |left, left_index|
      next if counts[left[:text]].to_i > SINGLE_CHARACTER_CLUSTER_MAX_OCCURRENCES

      occurrences[(left_index + 1)..].to_a.each do |right|
        distance = right[:start] - left[:start]
        break if distance > SINGLE_CHARACTER_CLUSTER_DISTANCE
        next if left[:text] == right[:text]
        next if counts[right[:text]].to_i > SINGLE_CHARACTER_CLUSTER_MAX_OCCURRENCES

        accepted_names << left[:text]
        accepted_names << right[:text]
      end
    end

    loop do
      before = accepted_names.length
      occurrences.each do |candidate|
        next if accepted_names.include?(candidate[:text])
        next if counts[candidate[:text]].to_i > SINGLE_CHARACTER_CLUSTER_MAX_OCCURRENCES

        nearby = occurrences.any? do |accepted|
          accepted_names.include?(accepted[:text]) &&
            (accepted[:start] - candidate[:start]).abs <= SINGLE_CHARACTER_CLUSTER_DISTANCE
        end
        accepted_names << candidate[:text] if nearby
      end
      break if accepted_names.length == before
    end

    occurrences.filter_map do |occurrence|
      next unless accepted_names.include?(occurrence[:text])

      candidates = occurrence[:candidates]
      top_score = candidates.first.fetch(:score)
      top = candidates.select { |candidate| candidate.fetch(:score) == top_score }
      {
        start: occurrence[:start],
        end: occurrence[:end],
        text: occurrence[:text],
        kind: "person",
        confidence: confidence_for(top, top_score),
        score: top_score,
        candidates: candidates.first(8)
      }
    end
  end

  def single_character_name_syntax?(index)
    previous = nearest_name_context_character(index - 1, -1)
    following = nearest_name_context_character(index + 1, 1)
    SINGLE_CHARACTER_FOLLOWERS.include?(following) || SINGLE_CHARACTER_PRECEDERS.include?(previous)
  end

  # Speech verbs are unusually useful local evidence in Literary Chinese.  A
  # chronologically plausible authority name immediately before 曰/云/謂/問/
  # 對/告/言/語/答 should beat a homographic place or office interpretation.
  # This is an occurrence-level score adjustment only; it cannot resurrect an
  # undated person rejected by the temporal gate.
  def person_speech_syntax_bonus(start_index, length)
    following = nearest_name_context_character(start_index + length, 1)
    PERSON_SPEECH_FOLLOWERS.include?(following) ? PERSON_SPEECH_SYNTAX_BONUS : 0
  end

  def nearest_name_context_character(index, direction)
    cursor = index
    while cursor >= 0 && cursor < @chars.length
      character = @chars[cursor].to_s
      return nil if character.match?(/[。！？!?；;\n\r]/)
      return character unless character.match?(/[\s，,、：:「」『』“”‘’]/)
      cursor += direction
    end
    nil
  end

  # The text can contain thousands of unique bigrams. Expanding every character
  # into a 12×12 Cartesian product creates a large transient query vocabulary.
  # Keep the literal form, each one-character substitution, and a small number
  # of combined substitutions. Historical names already store derived OpenCC
  # spellings, so this remains tolerant without exploding the request path.
  def equivalent_prefixes(prefix)
    @prefix_cache[prefix] ||= begin
      chars = prefix.each_char.to_a
      if chars.length != 2
        [prefix]
      else
        left = @equivalence.forms_for(chars[0]).to_a.sort
        right = @equivalence.forms_for(chars[1]).to_a.sort
        forms = [prefix]
        left.each { |form| forms << (form + chars[1]) unless form == chars[0] }
        right.each { |form| forms << (chars[0] + form) unless form == chars[1] }
        left.product(right).each do |a, b|
          combined = a + b
          forms << combined unless combined == prefix
          break if forms.length >= MAX_PREFIX_FORMS
        end
        forms.uniq.first(MAX_PREFIX_FORMS)
      end
    end
  end


  # The base annotator already knows explicit metadata dates. This extension
  # fills gaps with, in order: a single compatible regnal date in the text,
  # securely matched CBDB author chronology, then the known corpus period.
  def temporal_context
    base = super
    explicit_years = base["year_start"] || base["year_end"]
    period_range = annotation_period_range
    author_range = cbdb_author_range(period_range)
    regnal_dates = annotation_regnal_dates(author_range || period_range)

    chosen = if explicit_years
      nil
    elsif (year = unique_compatible_regnal_year(regnal_dates, author_range, period_range))
      { "year_start" => year, "year_end" => year }
    elsif author_range
      { "year_start" => author_range.fetch(:start), "year_end" => author_range.fetch(:end) }
    elsif period_range
      { "year_start" => period_range.fetch(:start), "year_end" => period_range.fetch(:end) }
    end

    base = base.merge(chosen || {})
    base["regnal_dates"] = regnal_dates if regnal_dates.any?
    base
  end

  # Attach one representative year to every dated authority candidate. This is
  # deliberately derived data for ranking/display; the original start/end range
  # remains intact and is still the authoritative chronology.
  # CBDB uses 0 as an unknown-year sentinel. The author pages already suppress
  # that value; automatic annotation must do the same or an undated person gains
  # a fictitious "0 CE" chronology and slips through the temporal gate.
  def cbdb_years(kind, detail)
    start_year, end_year = super
    [annotation_cbdb_year(start_year), annotation_cbdb_year(end_year)]
  end

  def annotation_cbdb_year(value)
    year = annotation_integer(value)
    year&.zero? ? nil : year
  end

  def cbdb_candidate(pointer, detail)
    candidate = super
    return nil unless candidate

    # BIOG_MAIN often has no usable birth/death/floruit year even though CBDB
    # does assign the person to a dynasty. Carry that existing CBDB fact into
    # the annotator so an undated Qing person cannot appear in a pre-Qin text.
    if candidate[:kind].to_s == "person"
      polity = cbdb_annotation_polity(detail)
      candidate = candidate.merge(polity: polity) if polity.present?
    end

    attach_annotation_chronology(candidate)
  end

  def historical_candidate(row)
    attach_annotation_chronology(super)
  end

  def attach_annotation_chronology(candidate)
    return nil unless candidate
    return candidate unless candidate[:kind].to_s == "person"

    range = candidate_annotation_range(candidate)
    # Automatic person annotation must have some temporal anchor. A bare name
    # with no personal chronology and no recognised polity is too weak to put
    # into running Classical Chinese, especially for one-character names.
    return nil unless range
    return nil if impossible_future_person?(range)

    # An open high-antiquity bound exists solely for the future-person gate.
    # Do not turn that conservative boundary into a displayed/ranking date.
    return candidate if range[:open_start]

    year = representative_year(range[:start], range[:end])
    year ? candidate.merge(representative_year: year) : candidate
  end

  def candidate_annotation_range(candidate)
    personal_start = annotation_integer(candidate[:year_start] || candidate[:year_end])
    personal_end = annotation_integer(candidate[:year_end] || candidate[:year_start])
    if personal_start || personal_end
      return { start: personal_start || personal_end, end: personal_end || personal_start }
    end

    # The curated high-antiquity authority deliberately records tradition, not
    # fictitious reign dates.  Give those records only an open upper bound for
    # the future-person gate and never expose -1600 as a life or reign year.
    if high_antiquity_authority_candidate?(candidate)
      return { start: nil, end: HIGH_ANTIQUITY_LATEST_YEAR, open_start: true }
    end

    annotation_range_for_value(candidate[:polity])
  end

  def high_antiquity_authority_candidate?(candidate)
    candidate.to_h[:authority_source].to_s == HIGH_ANTIQUITY_AUTHORITY_SOURCE ||
      candidate.to_h[:chronology_confidence].to_s == HIGH_ANTIQUITY_CHRONOLOGY_CONFIDENCE
  end

  # A text can cite people who lived earlier. It cannot name someone whose
  # earliest known personal or polity chronology begins after the latest
  # plausible date of the text. Polity is only a fallback when personal dates
  # are absent; it is never used to overwrite a known lifespan/floruit range.
  def impossible_future_person?(candidate_range)
    latest_text_year = annotation_integer(@context && @context["year_end"])
    earliest_person_year = annotation_integer(candidate_range && (candidate_range[:start] || candidate_range[:end]))
    latest_text_year && earliest_person_year && earliest_person_year > latest_text_year
  end

  def cbdb_annotation_polity(detail)
    code = annotation_first_value(detail, %w[c_dy c_dynasty c_dynasty_id])
    return nil if code.to_s.empty? || code.to_s == "0"
    return nil unless table_exists?("cbdb", "DYNASTIES")

    @cbdb_annotation_dynasty_cache ||= {}
    key = code.to_s
    return @cbdb_annotation_dynasty_cache[key] if @cbdb_annotation_dynasty_cache.key?(key)

    columns = table_columns("cbdb", "DYNASTIES")
    code_column = choose_column(columns, %w[c_dy c_dynasty c_dynasty_id])
    label_column = choose_column(columns, %w[c_dynasty_chn c_dynasty c_name_chn dynasty_chn])
    return @cbdb_annotation_dynasty_cache[key] = nil unless code_column && label_column

    @cbdb_annotation_dynasty_cache[key] = @db.get_first_value(
      "SELECT #{quote_identifier(label_column)} FROM cbdb.#{quote_identifier('DYNASTIES')} WHERE #{quote_identifier(code_column)} = ? LIMIT 1",
      [code]
    ).to_s.presence
  rescue StandardError => e
    Rails.logger&.debug("[authority] CBDB dynasty chronology skipped: #{e.class}: #{e.message}") if defined?(Rails)
    nil
  end

  def annotation_first_value(row, candidates)
    data = row.respond_to?(:to_h) ? row.to_h : {}
    candidates.each do |key|
      value = data[key] || data[key.to_sym]
      return value unless value.nil? || value.to_s.empty?
    end
    nil
  end

  def source_label(source)
    return "Fanya curated high-antiquity authority" if source.to_s == HIGH_ANTIQUITY_AUTHORITY_SOURCE

    super
  end

  # Date proximity breaks ties between otherwise equally scored people without
  # replacing the existing source/primary-name priorities.  Curated high-
  # antiquity records outrank accidental homographs from general databases.
  def candidate_sort_key(candidate)
    base = super
    base[3] = -HIGH_ANTIQUITY_SOURCE_PRIORITY if high_antiquity_authority_candidate?(candidate)
    centre = context_representative_year
    candidate_year = annotation_integer(candidate[:representative_year])
    distance = centre && candidate_year ? (candidate_year - centre).abs : 1_000_000
    [base.first, distance, *base.drop(1)]
  end

  # Once a span is securely recognized as a date, do not simultaneously present
  # an automatic person/place/office interpretation for the same characters.
  def resolve_overlaps(matches)
    resolved = super
    dates = Array(@context && @context["regnal_dates"])
    return resolved if dates.empty?

    resolved.reject do |match|
      dates.any? do |date|
        match[:start].to_i < date["end"].to_i && date["start"].to_i < match[:end].to_i
      end
    end
  end

  def context_representative_year
    left = annotation_integer(@context && @context["year_start"])
    right = annotation_integer(@context && @context["year_end"])
    representative_year(left, right)
  end

  def representative_year(start_year, end_year)
    left = annotation_integer(start_year || end_year)
    right = annotation_integer(end_year || start_year)
    return nil unless left || right
    return left || right unless left && right

    ((left + right) / 2.0).round
  end

  def annotation_period_range
    # Compare complete metadata values instead of doing substring matching over
    # one joined string. Single-graph dynasty labels such as 新 are legitimate,
    # but substring matching would also mistake 新羅 for the Chinese Xin dynasty.
    values = [@metadata["polity"], @metadata["period"], @metadata["region"]]
      .map { |value| value.to_s.strip }.reject(&:empty?).uniq
    values.each do |value|
      range = annotation_range_for_value(value)
      return range if range
    end
    nil
  end

  def annotation_range_for_value(value)
    label = value.to_s.strip
    return nil if label.empty?

    PERIOD_RANGES.each do |names, start_year, end_year|
      return { start: start_year, end: end_year } if names.include?(label)
    end
    nil
  end

  def metadata_author_names
    Array(@metadata["authors"]).filter_map do |entry|
      value = if entry.is_a?(Hash)
        entry["name"] || entry[:name] || entry["label"] || entry[:label]
      else
        entry
      end
      value.to_s.strip.presence
    end.uniq
  end

  # Author names are scholarly metadata, so an exact CBDB match is strong enough
  # to provide a circumstantial writing range. Generic/ambiguous names are only
  # used when the period evidence leaves one plausible CBDB identity.
  def cbdb_author_range(period_range)
    names = metadata_author_names
    return nil if names.empty? || !@store.respond_to?(:lookup_available?) || !@store.lookup_available?

    previous_db = @db
    rows = []
    @store.with_database do |db|
      @db = db
      names.each_slice(CbdbAutoAnnotator::PREFIX_BATCH_SIZE) do |slice|
        placeholders = (["?"] * slice.length).join(",")
        rows.concat(db.execute(<<~SQL, slice))
          SELECT prefix, name_length, name_chn, kind, entity_id, primary_name
          FROM cbdb_lookup.names
          WHERE kind = 'person' AND name_chn IN (#{placeholders})
        SQL
      end

      hydrated = hydrate_cbdb(rows)
      chosen = names.filter_map do |name|
        candidates = hydrated.filter_map do |row|
          next unless row["name_chn"].to_s == name
          row["candidate"]
        end
        candidates = candidates
          .compact
          .uniq { |candidate| [candidate[:authority_source], candidate[:id]] }
          .select { |candidate| candidate[:year_start] || candidate[:year_end] }

        if period_range
          compatible = candidates.select { |candidate| annotation_ranges_overlap?(candidate, period_range) }
          candidates = compatible if compatible.any?
        end

        # Do not turn a genuinely generic author string into a dating claim.
        next if candidates.map { |candidate| candidate[:id].to_s }.uniq.length > 3

        candidates.max_by do |candidate|
          [candidate[:primary] ? 1 : 0,
           candidate[:year_start] && candidate[:year_end] ? 1 : 0,
           candidate[:explicit] == false ? 0 : 1]
        end
      end

      return nil if chosen.empty?

      starts = chosen.filter_map { |candidate| annotation_integer(candidate[:year_start] || candidate[:year_end]) }
      ends = chosen.filter_map { |candidate| annotation_integer(candidate[:year_end] || candidate[:year_start]) }
      return nil if starts.empty? || ends.empty?

      # For multiple named authors, the useful composition window is their
      # overlapping lifetime/floruit interval. If there is no overlap, the
      # author list is probably describing a compilation or mixed contribution
      # history, so do not manufacture one broad author-derived writing range.
      range = { start: starts.max, end: ends.min }
      return nil if range[:start] > range[:end]

      if period_range && annotation_ranges_overlap?(range, period_range)
        range = {
          start: [range[:start], period_range[:start]].max,
          end: [range[:end], period_range[:end]].min
        }
      end
      range
    ensure
      @db = previous_db
    end
  rescue StandardError => e
    Rails.logger&.warn("[authority] CBDB author chronology skipped: #{e.class}: #{e.message}") if defined?(Rails)
    nil
  end

  def annotation_ranges_overlap?(candidate, range)
    left = annotation_integer(candidate[:year_start] || candidate[:start] || candidate["year_start"] || candidate["start"])
    right = annotation_integer(candidate[:year_end] || candidate[:end] || candidate["year_end"] || candidate["end"] || left)
    return false unless left && right

    right >= range.fetch(:start) && left <= range.fetch(:end)
  end

  # Regnal dates are useful even when they are quotations or narrated events, so
  # every unambiguously convertible occurrence is exposed for hover display.
  # Only a single period-compatible year is allowed to tighten the work's date.
  def annotation_regnal_dates(_context_range)
    resolver = HistoricalDateResolver.new(store: @store)
    # Hover conversion is descriptive, so a quoted date from another period is
    # still useful. Period/author chronology is applied later only when deciding
    # whether a unique date can narrow the work's own writing range.
    resolver_context = resolver.send(:build_context, @metadata)

    output = []
    @text.to_enum(:scan, HistoricalDateResolver::YEAR_EXPRESSION).each do
      match = Regexp.last_match
      split = resolver.send(:split_year_expression, match[1])
      next unless split

      prefix, numeral, year_number = split
      expression = {
        "prefix" => prefix,
        "year_number" => year_number,
        "surface" => "#{prefix}#{numeral}年"
      }
      resolution = resolver.send(:resolve_era_expression, expression, resolver_context)
      resolution ||= resolver.send(:resolve_regnal_expression, expression, resolver_context)
      next unless resolution&.resolved?

      matched_name = resolution.candidates.to_a.filter_map { |candidate| candidate["matched_name"].to_s.presence }.first
      matched_name ||= resolution.authority_name.to_s.presence
      next unless matched_name

      prefix_chars = prefix.each_char.to_a
      name_chars = matched_name.each_char.to_a
      relative_start = annotation_last_subsequence(prefix_chars, name_chars)
      next unless relative_start

      trailing = prefix_chars[(relative_start + name_chars.length)..].to_a.join
      # Include a sexagenary suffix when the era expression carries one, e.g.
      # 太平天國癸好三年. Other preceding prose is deliberately excluded.
      trailing = "" unless trailing.empty? || trailing.match?(HistoricalDateResolver::SEXAGENARY_SUFFIX)
      surface = "#{matched_name}#{trailing}#{numeral}年"
      full_match_start = @text[0...match.begin(0)].to_s.each_char.count
      start_index = full_match_start + relative_start
      end_index = start_index + surface.each_char.count

      first_candidate = resolution.candidates.to_a.first || {}
      output << {
        "start" => start_index,
        "end" => end_index,
        "text" => @chars[start_index, end_index - start_index].to_a.join,
        "absolute_year" => resolution.year_start,
        "authority_name" => resolution.authority_name,
        "authority_kind" => resolution.authority_kind,
        "confidence" => resolution.confidence,
        "source" => resolution.source,
        "source_url" => first_candidate["source_url"]
      }.compact
    end

    output.uniq { |row| [row["start"], row["end"], row["absolute_year"], row["authority_name"]] }
  rescue StandardError => e
    Rails.logger&.warn("[authority] regnal-date annotation skipped: #{e.class}: #{e.message}") if defined?(Rails)
    []
  end

  def annotation_last_subsequence(haystack, needle)
    return nil if needle.empty? || needle.length > haystack.length

    (haystack.length - needle.length).downto(0) do |index|
      return index if haystack[index, needle.length] == needle
    end
    nil
  end

  def unique_compatible_regnal_year(dates, author_range, period_range)
    # Repeated instances of the same era/year are fine. Two different regnal
    # systems that happen to map to the same CE year are a comparison, not a
    # unique document date signal.
    distinct = Array(dates).filter_map do |row|
      year = annotation_integer(row["absolute_year"])
      name = row["authority_name"].to_s.strip
      next unless year && !name.empty?

      [name, year]
    end.uniq
    return nil unless distinct.length == 1

    year = distinct.first.last
    return nil if author_range && !year.between?(author_range.fetch(:start), author_range.fetch(:end))
    return nil if period_range && !year.between?(period_range.fetch(:start), period_range.fetch(:end))

    year
  end

  def annotation_integer(value)
    Integer(value) if value.to_s.match?(/\A-?\d+\z/)
  rescue ArgumentError, TypeError
    nil
  end

  def safe_authority_metadata
    @store.metadata.to_h.stringify_keys
  rescue StandardError => e
    log_source_failure("metadata", e)
    {}
  end

  def log_source_failure(source, error)
    return unless defined?(Rails) && Rails.respond_to?(:logger)

    Rails.logger&.warn("[authority] #{source} automatic annotation source failed: #{error.class}: #{error.message}")
  end
end
