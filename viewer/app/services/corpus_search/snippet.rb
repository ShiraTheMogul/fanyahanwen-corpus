# frozen_string_literal: true

module CorpusSearch
  # Builds KWIC-ish snippets.
  #
  # Offsets are character offsets into the body text, not byte offsets and not
  # full-file offsets including front matter.
  class Snippet
    def self.build(text, start_offset:, end_offset:, context: 20, collapse_after: 260)
      new(text, start_offset: start_offset, end_offset: end_offset, context: context, collapse_after: collapse_after).build
    end

    def initialize(text, start_offset:, end_offset:, context: 20, collapse_after: 260)
      @chars = SearchText.chars_for(text)
      @start_offset = [start_offset.to_i, 0].max
      @end_offset = [end_offset.to_i, @start_offset].max
      @context = [[context.to_i, 0].max, 500].min
      @collapse_after = [[collapse_after.to_i, 80].max, 2_000].min
    end

    def build
      left_start = [@start_offset - @context, 0].max
      right_end = [@end_offset + @context, @chars.length].min

      left = @chars[left_start...@start_offset].to_a.join
      matched = @chars[@start_offset...@end_offset].to_a.join
      right = @chars[@end_offset...right_end].to_a.join

      {
        "left_context" => left,
        "matched_text" => collapsed(matched),
        "right_context" => right,
        "snippet" => [left, collapsed(matched), right].join,
        "start_offset" => @start_offset,
        "end_offset" => @end_offset
      }
    end

    private

    def collapsed(text)
      chars = text.each_char.to_a
      return text if chars.length <= @collapse_after

      head = chars.first(80).join
      tail = chars.last(80).join
      omitted = chars.length - 160

      omission = I18n.t("corpus_search.results.chars_omitted", count: omitted)
      "#{head}……[#{omission}]……#{tail}"
    end
  end
end
