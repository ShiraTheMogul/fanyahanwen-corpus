# frozen_string_literal: true

require "uri"

module CorpusSearch
  # Builds a stable viewer link for one body occurrence without changing routes.
  # The path is escaped segment-by-segment so Han characters and spaces remain safe.
  module SourceLink
    module_function

    def relative_url(path:, start_offset: nil, end_offset: nil, source: "corpus_search")
      segments = path.to_s.split("/").reject(&:empty?).map { |segment| URI.encode_uri_component(segment) }
      base = "/corpus_viewer/#{segments.join('/')}"
      query = { start: start_offset, end: end_offset, source: source }.compact
      query.empty? ? base : "#{base}?#{URI.encode_www_form(query)}"
    end
  end
end
