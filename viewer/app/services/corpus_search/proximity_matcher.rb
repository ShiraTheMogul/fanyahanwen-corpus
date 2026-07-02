# frozen_string_literal: true

require "set"

module CorpusSearch
  # Finds compact passage windows containing every proximity term.
  #
  # The matcher works on the normalized character stream. It returns search
  # offsets only; Runner maps those offsets back to the original body text.
  # Repeated terms are treated as separate requirements, so 民 + 民 needs two
  # distinct occurrences rather than one occurrence counted twice.
  class ProximityMatcher
    Match = Data.define(:search_start, :search_end, :term_matches)
    TermMatch = Data.define(:term_index, :search_start, :search_end)

    def initialize(searchable_units:, term_patterns: nil, term_units: nil, maximum_span:, order: "any")
      @searchable_units = searchable_units
      @term_patterns = normalize_patterns(term_patterns || term_units)
      @maximum_span = maximum_span.to_i
      @order = order.to_s == "entered" ? "entered" : "any"
    end

    def matches
      return [] if @term_patterns.length < 2
      return [] if @term_patterns.any?(&:empty?)

      @order == "entered" ? entered_order_matches : any_order_matches
    end

    private

    def any_order_matches
      groups = grouped_terms
      return [] if groups.any? { |group| group[:positions].length < group[:required] }

      events = groups.flat_map do |group|
        group[:positions].map do |position|
          {
            group_id: group[:id],
            search_start: position,
            search_end: position + group[:pattern].length
          }
        end
      end.sort_by { |event| [event[:search_start], event[:search_end], event[:group_id]] }

      required = groups.to_h { |group| [group[:id], group[:required]] }
      term_indices = groups.to_h { |group| [group[:id], group[:term_indices]] }
      counts = Hash.new(0)
      left = 0
      right = 0
      results = []
      seen = Set.new

      while right < events.length
        counts[events[right][:group_id]] += 1

        if requirements_met?(counts, required)
          # Remove surplus occurrences from the left. The remaining left-most
          # event is essential, giving one compact window rather than every
          # combinatorial pairing inside a dense passage.
          while left <= right && counts[events[left][:group_id]] > required.fetch(events[left][:group_id])
            counts[events[left][:group_id]] -= 1
            left += 1
          end

          selected = select_required_events(events, left, right, required, term_indices)
          add_match(results, seen, selected) if selected

          counts[events[left][:group_id]] -= 1
          left += 1
        end

        right += 1
      end

      results
    end

    def entered_order_matches
      positions_by_term = @term_patterns.map { |pattern| SearchText.positions_of_pattern(@searchable_units, pattern) }
      return [] if positions_by_term.any?(&:empty?)

      results = []
      seen = Set.new

      positions_by_term.first.each do |first_position|
        selected = [TermMatch.new(term_index: 0, search_start: first_position, search_end: first_position + @term_patterns.first.length)]
        used_occurrences = Set.new([[term_signature(@term_patterns.first), first_position]])
        previous_position = first_position
        failed = false

        (1...@term_patterns.length).each do |term_index|
          pattern = @term_patterns[term_index]
          signature = term_signature(pattern)
          candidate = next_position(
            positions_by_term[term_index],
            minimum: previous_position,
            signature: signature,
            used_occurrences: used_occurrences
          )

          unless candidate
            failed = true
            break
          end

          selected << TermMatch.new(
            term_index: term_index,
            search_start: candidate,
            search_end: candidate + pattern.length
          )
          used_occurrences << [signature, candidate]
          previous_position = candidate
        end

        add_match(results, seen, selected) unless failed
      end

      results
    end

    def grouped_terms
      grouped = {}

      @term_patterns.each_with_index do |pattern, term_index|
        signature = term_signature(pattern)
        grouped[signature] ||= {
          id: grouped.length,
          pattern: pattern,
          required: 0,
          term_indices: []
        }
        grouped[signature][:required] += 1
        grouped[signature][:term_indices] << term_index
      end

      grouped.values.each do |group|
        group[:positions] = SearchText.positions_of_pattern(@searchable_units, group[:pattern])
      end
    end

    def requirements_met?(counts, required)
      required.all? { |group_id, amount| counts[group_id] >= amount }
    end

    def select_required_events(events, left, right, required, term_indices)
      events_by_group = events[left..right].group_by { |event| event[:group_id] }
      selected = []

      required.each do |group_id, amount|
        candidates = Array(events_by_group[group_id]).first(amount)
        return nil if candidates.length < amount

        candidates.zip(term_indices.fetch(group_id)).each do |event, term_index|
          selected << TermMatch.new(
            term_index: term_index,
            search_start: event[:search_start],
            search_end: event[:search_end]
          )
        end
      end

      selected.sort_by(&:term_index)
    end

    def next_position(positions, minimum:, signature:, used_occurrences:)
      index = lower_bound(positions, minimum)

      while index < positions.length
        position = positions[index]
        return position unless used_occurrences.include?([signature, position])

        index += 1
      end

      nil
    end

    def lower_bound(values, minimum)
      low = 0
      high = values.length

      while low < high
        middle = (low + high) / 2
        if values[middle] < minimum
          low = middle + 1
        else
          high = middle
        end
      end

      low
    end

    def add_match(results, seen, selected)
      return if selected.nil? || selected.empty?

      search_start = selected.map(&:search_start).min
      search_end = selected.map(&:search_end).max
      return if search_end - search_start > @maximum_span

      key = selected.sort_by(&:term_index).map { |match| [match.term_index, match.search_start, match.search_end] }
      return if seen.include?(key)

      seen << key
      results << Match.new(
        search_start: search_start,
        search_end: search_end,
        term_matches: selected.sort_by(&:term_index)
      )
    end

    def term_signature(pattern)
      pattern.map { |forms| forms.to_a.sort.join("\u0001") }.join("\u0000")
    end

    def normalize_patterns(values)
      Array(values).map do |pattern|
        Array(pattern).map do |forms|
          forms.respond_to?(:include?) && !forms.is_a?(String) ? forms : Set[forms.to_s]
        end
      end
    end
  end
end
