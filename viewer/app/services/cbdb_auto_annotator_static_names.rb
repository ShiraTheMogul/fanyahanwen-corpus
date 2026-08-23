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
  SINGLE_CHARACTER_FOLLOWERS = %w[曰 云 謂 谓 問 问 對 对 告].freeze
  SINGLE_CHARACTER_PRECEDERS = %w[爾 尔 命 召 呼].freeze

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
      if authority_row_count(name_rows) > SINGLE_CHARACTER_MAX_CANDIDATES
        output[name] = :ambiguous
        next
      end

      candidates = name_rows.filter_map { |row| historical_candidate(row) }
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
        target[name] = :ambiguous
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
    previous = nearest_nonspace_character(index - 1, -1)
    following = nearest_nonspace_character(index + 1, 1)
    SINGLE_CHARACTER_FOLLOWERS.include?(following) || SINGLE_CHARACTER_PRECEDERS.include?(previous)
  end

  def nearest_nonspace_character(index, direction)
    cursor = index
    while cursor >= 0 && cursor < @chars.length
      character = @chars[cursor].to_s
      return character unless character.match?(/\s/)
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
