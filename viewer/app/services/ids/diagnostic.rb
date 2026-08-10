# frozen_string_literal: true

module Ids
  # Read and parse a yi-bai/ids source without touching the database.
  #
  # This is intentionally the same parser path used by Importer. It gives us a
  # quick compatibility check whenever the upstream notation or Unicode
  # repertoire changes, before a long database transaction starts.
  class Diagnostic
    Sample = Struct.new(:line_number, :error, :source, keyword_init: true)
    Result = Struct.new(
      :lines,
      :ignored,
      :rows,
      :candidates,
      :source_errors,
      :candidate_errors,
      :empty_rows,
      :source_error_samples,
      :candidate_error_samples,
      :empty_row_samples,
      keyword_init: true
    ) do
      def clean?
        source_errors.zero? && candidate_errors.zero? && empty_rows.zero?
      end
    end

    def initialize(row_parser: SourceRowParser.new, sample_limit: 20)
      @row_parser = row_parser
      @sample_limit = Integer(sample_limit)
    end

    def run(level:, path: nil, url: nil, io: nil)
      level = level.to_s
      stream = io || CharacterData::Utf8Stream.open(
        path: path,
        url: url || Importer::DEFAULT_URLS.fetch(level),
        read_timeout: 60
      )
      result = Result.new(
        lines: 0,
        ignored: 0,
        rows: 0,
        candidates: 0,
        source_errors: 0,
        candidate_errors: 0,
        empty_rows: 0,
        source_error_samples: [],
        candidate_error_samples: [],
        empty_row_samples: []
      )

      stream.each_line do |line|
        result.lines += 1
        source_error = false
        source_row = begin
          @row_parser.parse(line)
        rescue SourceRowParser::ParseError => error
          source_error = true
          result.source_errors += 1
          append_sample(result.source_error_samples, result.lines, error.message, line)
          nil
        end

        unless source_row
          result.ignored += 1 unless source_error
          next
        end

        result.rows += 1
        if source_row.candidates.empty?
          result.empty_rows += 1
          append_sample(result.empty_row_samples, result.lines, "row has no IDS candidates", line)
          next
        end

        source_row.candidates.each do |candidate|
          result.candidates += 1
          begin
            Parser.parse(candidate.expression)
          rescue Parser::ParseError => error
            result.candidate_errors += 1
            append_sample(
              result.candidate_error_samples,
              result.lines,
              error.message,
              candidate.raw_expression
            )
          end
        end
      end

      result
    ensure
      stream.close if stream && stream.respond_to?(:close) && io.nil?
    end

    private

    def append_sample(collection, line_number, error, source)
      return if collection.length >= @sample_limit

      collection << Sample.new(
        line_number: line_number,
        error: error,
        source: source.to_s.chomp[0, 300]
      )
    end
  end
end
