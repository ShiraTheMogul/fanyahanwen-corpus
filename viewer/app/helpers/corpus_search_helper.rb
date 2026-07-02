# frozen_string_literal: true

module CorpusSearchHelper
  # Renders the visible snippet while highlighting each matched proximity term.
  # Exact-sequence searches still receive one mark around the whole match.
  def corpus_search_snippet(hit)
    left = hit["left_context"].to_s
    matched = hit["matched_text"].to_s
    right = hit["right_context"].to_s
    visible = [left, matched, right].join

    body_visible_start = hit["start_offset"].to_i - left.each_char.count
    ranges = highlighted_ranges(hit).filter_map do |range_start, range_end|
      relative_start = range_start.to_i - body_visible_start
      relative_end = range_end.to_i - body_visible_start
      next if relative_end <= 0 || relative_start >= visible.each_char.count

      [[relative_start, 0].max, [relative_end, visible.each_char.count].min]
    end

    render_highlighted_text(visible, merge_ranges(ranges))
  end

  private

  def highlighted_ranges(hit)
    term_matches = Array(hit["term_matches"])
    return [[hit["start_offset"], hit["end_offset"]]] if term_matches.empty?

    term_matches.map { |match| [match["start_offset"], match["end_offset"]] }
  end

  def merge_ranges(ranges)
    ranges.sort_by(&:first).each_with_object([]) do |range, merged|
      if merged.empty? || range.first > merged.last.last
        merged << range.dup
      else
        merged.last[1] = [merged.last.last, range.last].max
      end
    end
  end

  def render_highlighted_text(text, ranges)
    chars = text.each_char.to_a
    cursor = 0
    fragments = []

    ranges.each do |range_start, range_end|
      fragments << ERB::Util.html_escape(chars[cursor...range_start].to_a.join)
      fragments << content_tag(:mark, chars[range_start...range_end].to_a.join)
      cursor = range_end
    end

    fragments << ERB::Util.html_escape(chars[cursor..].to_a.join)
    safe_join(fragments)
  end
end
