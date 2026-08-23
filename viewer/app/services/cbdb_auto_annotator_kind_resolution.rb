# frozen_string_literal: true

# Keep homographic authority records separated by entity kind until overlap
# resolution. The base annotator previously merged a person/clan/place/office sharing
# the same written name into one candidate list, so the displayed kind depended
# on whichever candidate happened to sort first.
module CbdbAutoAnnotatorKindResolution
  private

  def build_multi_matches(rows)
    by_prefix = Hash.new do |hash, prefix|
      hash[prefix] = Hash.new { |inner, key| inner[key] = [] }
    end

    rows.each do |row|
      name = row["name_chn"].to_s
      candidate = row["candidate"]
      next if name.each_char.count < 2 || !candidate

      kind = candidate[:kind].to_s.presence || row["kind"].to_s.presence || "person"
      prefix = name.each_char.take(2).join
      by_prefix[prefix][[name, kind]] << candidate
    end

    by_prefix.each_value do |groups|
      groups.each_value do |candidates|
        candidates.uniq! { |candidate| [candidate[:authority_source], candidate[:id], candidate[:derivation]] }
        candidates.sort_by! { |candidate| candidate_sort_key(candidate) }
      end
    end

    matches = []
    index = 0
    while index < @chars.length - 1
      literal_prefix = @chars[index, 2].join
      unless @chars[index].to_s.match?(/\p{Han}/) && @chars[index + 1].to_s.match?(/\p{Han}/)
        index += 1
        next
      end

      groups = equivalent_prefixes(literal_prefix)
        .flat_map { |prefix| by_prefix[prefix].to_a }
        .group_by(&:first)
        .transform_values { |pairs| pairs.flat_map(&:last) }

      if groups.empty?
        index += 1
        next
      end

      matched_name = groups.keys.map(&:first).uniq
        .sort_by { |name| -name.each_char.count }
        .find { |name| name_matches_at?(name, index) }
      unless matched_name
        index += 1
        next
      end

      length = matched_name.each_char.count
      groups.each do |(name, kind), raw_candidates|
        next unless name == matched_name

        syntax_bonus = if respond_to?(:authority_kind_syntax_bonus, true)
          authority_kind_syntax_bonus(kind, index, length)
        elsif kind == "person" && respond_to?(:person_speech_syntax_bonus, true)
          person_speech_syntax_bonus(index, length)
        else
          0
        end

        candidates = raw_candidates
          .map do |candidate|
            next candidate if syntax_bonus.zero?
            candidate.merge(score: candidate.fetch(:score) + syntax_bonus)
          end
          .uniq { |candidate| [candidate[:authority_source], candidate[:id], candidate[:derivation]] }
          .sort_by { |candidate| candidate_sort_key(candidate) }
        next if candidates.empty?

        top_score = candidates.first.fetch(:score)
        top = candidates.select { |candidate| candidate.fetch(:score) == top_score }
        matches << {
          start: index,
          end: index + length,
          text: @chars[index, length].join,
          kind: kind,
          confidence: confidence_for(top, top_score),
          score: top_score,
          candidates: candidates.first(8)
        }
      end

      index += length
    end

    matches
  end
end
