# frozen_string_literal: true

require "csv"
require "json"
require "pathname"

module CorpusSearch
  # Read-only view over the structured files created by the application-owned R
  # profile. Paths are resolved beneath one prepared-search analysis directory;
  # no visitor-supplied path is ever opened.
  class AnalysisReport
    METRICS = %w[
      occurrences
      matching_documents
      document_prevalence
      occurrences_per_million
    ].freeze

    DIMENSIONS = %w[period nation region author folder document_role].freeze

    attr_reader :directory, :payload

    def self.load(directory)
      root = Pathname(directory).expand_path
      report_path = root.join("analysis_report.json")
      return nil unless report_path.file?

      new(directory: root, payload: JSON.parse(report_path.read(encoding: "UTF-8")))
    rescue JSON::ParserError, Errno::ENOENT
      nil
    end

    def initialize(directory:, payload:)
      @directory = Pathname(directory).expand_path
      @payload = payload.to_h
    end

    def overall
      payload.fetch("overall", {}).to_h
    end

    def charts
      Array(payload["charts"]).map(&:to_h)
    end

    def chart(dimension:, metric:)
      charts.find do |chart|
        chart["dimension"].to_s == dimension.to_s && chart["metric"].to_s == metric.to_s
      end
    end

    def special_chart(key)
      charts.find { |chart| chart["key"].to_s == key.to_s }
    end

    def svg(chart)
      return nil unless chart

      read_relative(chart["svg"])
    end

    def table(name, limit: nil)
      relative = payload.fetch("tables", {}).to_h[name.to_s]
      return [] if relative.blank?

      path = safe_relative_path(relative)
      return [] unless path&.file?

      rows = CSV.read(path, headers: true, encoding: "bom|utf-8").map(&:to_h)
      limit ? rows.first(limit) : rows
    rescue CSV::MalformedCSVError, Errno::ENOENT
      []
    end

    def warnings
      content = read_relative("warnings.txt")
      content.to_s.lines.map(&:strip).reject(&:blank?).uniq
    end

    def r_session
      read_relative("sessionInfo.txt")
    end

    private

    def read_relative(relative)
      path = safe_relative_path(relative)
      path&.file? ? path.read(encoding: "UTF-8") : nil
    rescue ArgumentError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
      path&.binread&.force_encoding(Encoding::UTF_8)&.scrub
    end

    def safe_relative_path(relative)
      value = relative.to_s
      return nil if value.blank?

      candidate_relative = Pathname(value)
      return nil if candidate_relative.absolute? || candidate_relative.each_filename.any? { |part| part == ".." }

      candidate = directory.join(candidate_relative).cleanpath
      root_prefix = "#{directory.cleanpath}#{File::SEPARATOR}"
      return nil unless candidate.to_s.start_with?(root_prefix)

      candidate
    end
  end
end
