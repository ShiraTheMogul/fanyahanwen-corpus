# frozen_string_literal: true

# Small resilience fixes for the automatic historical annotator.
#
# This module deliberately reuses CbdbAutoAnnotatorStaticNames' chronology,
# authority, ambiguity, and syntax rules. It only repairs three edge cases:
#   * the :ambiguous one-character sentinel must never be treated as a candidate;
#   * failure of optional one-character enrichment must not discard otherwise
#     successful annotations from the same authority source;
#   * era dates used descriptively in quoted historical material may be converted
#     even when the era's local-use interval does not match the work's own period.
module CbdbAutoAnnotatorStability
  private

  def cbdb_single_character_candidates
    super
  rescue StandardError => e
    log_source_failure("CBDB one-character people", e)
    {}
  end

  def historical_single_character_candidates
    super
  rescue StandardError => e
    log_source_failure("historical one-character people", e)
    {}
  end

  def merge_single_character_candidates!(target, source)
    source.to_h.each do |name, candidates|
      if candidates == :ambiguous || target[name] == :ambiguous
        combined = [target[name], candidates].flat_map do |value|
          value == :ambiguous ? [] : Array(value)
        end.compact
        curated = combined.select { |candidate| high_antiquity_authority_candidate?(candidate) }
        target[name] = if curated.any?
          specific_single_character_candidates(curated)
        else
          :ambiguous
        end
        next
      end

      combined = [*Array(target[name]), *Array(candidates)]
      merged = specific_single_character_candidates(combined)
      target[name] = combined.any? && merged.empty? ? :ambiguous : merged
    end
  end

  def high_antiquity_authority_candidate?(candidate)
    return false unless candidate.respond_to?(:to_h)

    data = candidate.to_h
    data[:authority_source].to_s == CbdbAutoAnnotatorStaticNames::HIGH_ANTIQUITY_AUTHORITY_SOURCE ||
      data[:chronology_confidence].to_s == CbdbAutoAnnotatorStaticNames::HIGH_ANTIQUITY_CHRONOLOGY_CONFIDENCE
  end

  # Regnal/era occurrences are annotations first. A work from 東寧 can quote an
  # earlier 永曆 year, and that quoted year is still useful to convert for the
  # reader. Local-use compatibility is applied later when deciding whether an
  # occurrence may tighten the work's own chronology.
  def annotation_regnal_dates(_context_range)
    resolver = HistoricalDateResolver.new(store: @store)
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

      era_candidates = resolver.send(
        :era_resolution_candidates,
        expression,
        resolver_context,
        include_out_of_range: true
      ).select { |candidate| candidate.fetch("score") > -100 }
      resolution = resolver.send(:choose_resolution, era_candidates, expression, authority_kind: "era")
      resolution ||= resolver.send(:resolve_regnal_expression, expression, resolver_context)
      next unless resolution&.resolved?

      matched_name = resolution.candidates.to_a.filter_map do |candidate|
        candidate["matched_name"].to_s.presence
      end.first
      matched_name ||= resolution.authority_name.to_s.presence
      next unless matched_name

      prefix_chars = prefix.each_char.to_a
      name_chars = matched_name.each_char.to_a
      relative_start = annotation_last_subsequence(prefix_chars, name_chars)
      next unless relative_start

      trailing = prefix_chars[(relative_start + name_chars.length)..].to_a.join
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

    output.uniq do |row|
      [row["start"], row["end"], row["absolute_year"], row["authority_name"]]
    end
  rescue StandardError => e
    Rails.logger&.warn("[authority] regnal-date annotation skipped: #{e.class}: #{e.message}") if defined?(Rails)
    []
  end
end
