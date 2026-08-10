# frozen_string_literal: true

module Ids
  class Importer
    DEFAULT_SOURCE = "yi-bai/ids"
    DEFAULT_VERSION = "8b8a58093b97bd80e5a51c3b19dfa47261b82bf7"
    LEVELS = %w[lv0 lv1 lv2].freeze
    DEFAULT_URLS = {
      "lv0" => "https://raw.githubusercontent.com/yi-bai/ids/#{DEFAULT_VERSION}/ids_lv0.txt",
      "lv1" => "https://raw.githubusercontent.com/yi-bai/ids/#{DEFAULT_VERSION}/ids_lv1.txt",
      "lv2" => "https://raw.githubusercontent.com/yi-bai/ids/#{DEFAULT_VERSION}/ids_lv2.txt"
    }.freeze

    class ImportError < StandardError; end

    Result = Struct.new(
      :lines,
      :rows,
      :candidates,
      :structures,
      :source_errors,
      :candidate_errors,
      :empty_rows,
      :characters,
      keyword_init: true
    ) do
      def clean?
        source_errors.zero? && candidate_errors.zero? && empty_rows.zero?
      end
    end

    def initialize(source: DEFAULT_SOURCE, source_version: DEFAULT_VERSION, row_parser: SourceRowParser.new)
      @source = source
      @source_version = source_version
      @row_parser = row_parser
    end

    # yi-bai/ids imports are strict by default. A parser incompatibility must
    # roll back the transaction instead of quietly producing a partial index.
    def import(level:, path: nil, url: nil, replace: false, strict: true, io: nil)
      level = level.to_s
      stream = io || open_stream(path: path, url: url || DEFAULT_URLS.fetch(level))
      result = Result.new(
        lines: 0,
        rows: 0,
        candidates: 0,
        structures: 0,
        source_errors: 0,
        candidate_errors: 0,
        empty_rows: 0,
        characters: 0
      )
      resolved_character_ids = {}

      ActiveRecord::Base.transaction do
        if replace
          old_scope = CharacterStructure.where(system: "ids", source: @source, source_level: level)
          CharacterStructureComponent.where(character_structure_id: old_scope.select(:id)).delete_all
          old_scope.delete_all
        end

        stream.each_line do |line|
          result.lines += 1
          source_row = parse_source_row(line, result)
          next unless source_row

          result.rows += 1
          if source_row.candidates.empty?
            result.empty_rows += 1
            next
          end

          valid_candidates = source_row.candidates.filter_map do |candidate|
            result.candidates += 1
            begin
              tree = Parser.parse(candidate.expression)
              [candidate, tree]
            rescue Parser::ParseError
              result.candidate_errors += 1
              nil
            end
          end

          next if valid_candidates.empty?

          character_id = resolve_character_id(source_row.glyph, resolved_character_ids)

          # The same normalized IDS can occur in both the primary and
          # alternative columns. Store one searchable structure and preserve
          # every upstream occurrence in metadata.
          grouped = valid_candidates.group_by { |candidate, _tree| Parser.normalize(candidate.expression) }
          grouped.each_value do |candidate_pairs|
            candidate, tree = candidate_pairs.first
            normalized = Parser.normalize(candidate.expression)
            leaves = Parser.leaves(tree)
            operators = Parser.operators(tree)
            register_literal_components(leaves, resolved_character_ids)
            variants = candidate_pairs.map do |entry, _entry_tree|
              {
                "raw_expression" => entry.raw_expression,
                "list_type" => entry.list_type,
                "field_index" => entry.field_index,
                "indicators" => entry.indicators,
                "annotations" => entry.annotations
              }
            end.uniq

            structure = CharacterStructure.find_or_initialize_by(
              character_codepoint_id: character_id,
              system: "ids",
              normalized_expression: normalized,
              source: @source,
              source_level: level,
              glyph_region: ""
            )
            structure.assign_attributes(
              expression: candidate.expression,
              top_level_operator: Parser.top_operator(tree),
              component_signature: signature(leaves),
              operator_signature: signature(operators),
              leaf_count: leaves.length,
              source_version: @source_version,
              glyph_region: "",
              metadata: {
                "raw_line" => line.chomp,
                "variants" => variants,
                "license" => "MIT"
              }
            )
            structure.save!

            structure.components.delete_all
            Parser.component_rows(tree).each { |attrs| structure.components.create!(attrs) }
            result.structures += 1
          end

          if (result.lines % 10_000).zero?
            puts "[ids] #{level}: lines=#{result.lines} structures=#{result.structures} source_errors=#{result.source_errors} candidate_errors=#{result.candidate_errors} empty_rows=#{result.empty_rows}"
          end
        end

        result.characters = resolved_character_ids.length

        if strict && !result.clean?
          raise ImportError,
                "#{@source} #{level} is not fully understood: " \
                "source_errors=#{result.source_errors}, " \
                "candidate_errors=#{result.candidate_errors}, " \
                "empty_rows=#{result.empty_rows}. " \
                "Transaction rolled back; run character_data:diagnose_ids LEVEL=#{level}."
        end

        if result.rows.positive? && result.structures.zero?
          raise ImportError,
                "#{@source} #{level} contained #{result.rows} data rows but produced zero valid IDS structures"
        end
      end

      result
    ensure
      stream.close if stream && stream.respond_to?(:close) && io.nil?
    end

    private

    def open_stream(path:, url:)
      CharacterData::Utf8Stream.open(path: path, url: url, read_timeout: 60)
    end

    def parse_source_row(line, result)
      @row_parser.parse(line)
    rescue SourceRowParser::ParseError
      result.source_errors += 1
      nil
    end

    def signature(tokens)
      tokens.tally.sort_by { |token, _count| token }.map { |token, count| "#{token}:#{count}" }.join(" ")
    end

    def register_literal_components(leaves, cache)
      leaves.uniq.each do |token|
        next unless CharacterData::IndexableCharacter.single?(token)

        resolve_character_id(token, cache)
      end
    end

    def resolve_character_id(glyph, cache)
      codepoint = glyph.ord
      cache[codepoint] ||= CharacterData::CodepointResolver.resolve_glyph(glyph).id
    end
  end
end
