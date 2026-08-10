# frozen_string_literal: true

module CharacterData
  class RimeCodeImporter
    class ImportError < StandardError; end

    Result = Struct.new(
      :lines, :codes, :skipped, :characters, :tables,
      :skipped_multi_character, :skipped_empty_code, :skipped_malformed, :skip_samples,
      keyword_init: true
    )

    def import(system_id:, path: nil, url: nil, source: nil, source_version: nil, format: nil, kind: nil, replace: false, io: nil)
      preset = SourceCatalogue::SOURCES[system_id.to_s] || {}
      system_id = system_id.to_s
      source ||= preset[:source] || "RIME"
      source_version ||= preset[:version]
      format ||= preset[:format] || "rime_dict"
      kind ||= preset[:kind] || "input"
      url ||= preset[:url]
      raise ArgumentError, "provide FILE=... or URL=..." if path.blank? && url.blank? && io.nil?

      result = Result.new(
        lines: 0, codes: 0, skipped: 0, characters: 0, tables: 0,
        skipped_multi_character: 0, skipped_empty_code: 0, skipped_malformed: 0, skip_samples: []
      )
      touched = {}
      seen_tables = {}

      ActiveRecord::Base.transaction do
        CharacterInputCode.where(system_id: system_id, source: source).delete_all if replace

        each_source_line(path: path, url: url, io: io, format: format) do |source_line|
          result.lines += 1
          table_name = source_line[:source_table]
          if table_name.present? && !seen_tables[table_name]
            seen_tables[table_name] = true
            result.tables += 1
          end

          stripped = source_line.fetch(:line).to_s.delete_prefix("\uFEFF").chomp
          next if stripped.blank? || stripped.lstrip.start_with?("#")

          row, skip_reason = parse_row(
            stripped,
            format: format,
            default_kind: kind,
            columns: source_line[:columns]
          )
          unless row
            record_skip(
              result,
              reason: skip_reason || :malformed,
              line: stripped,
              source_table: table_name,
              source_location: source_line[:source_location]
            )
            next
          end

          character = CodepointResolver.resolve(codepoint: row.fetch(:character).ord, glyph: row.fetch(:character))
          touched[character.id] = true
          attrs = {
            character_codepoint_id: character.id,
            system_id: system_id,
            code: row.fetch(:code),
            kind: row.fetch(:kind),
            source: source
          }
          record = CharacterInputCode.find_or_initialize_by(attrs)
          record.source_version = source_version
          record.metadata = (row[:metadata] || {}).merge(
            "license" => preset[:license],
            "source_table" => table_name,
            "source_location" => source_line[:source_location]
          ).compact
          record.save!
          result.codes += 1

          if (result.codes % 10_000).zero?
            puts "[rime-codes] #{system_id}: codes=#{result.codes} characters=#{touched.length} tables=#{result.tables}"
          end
        end
      end

      result.characters = touched.length
      if result.lines.positive? && result.codes.zero?
        raise ImportError,
              "#{system_id} read #{result.lines} dictionary body lines from #{result.tables} table(s) but produced zero single-character codes"
      end

      result
    end

    private

    def each_source_line(path:, url:, io:, format:)
      return enum_for(:each_source_line, path: path, url: url, io: io, format: format) unless block_given?

      if format.to_s == "rime_dict"
        RimeDictionaryReader.new(path: path, url: url, io: io).each do |entry|
          yield line: entry.line,
                source_table: entry.source_table,
                source_location: entry.source_location,
                columns: entry.columns
        end
      else
        stream = nil
        begin
          stream = io || Utf8Stream.open(path: path, url: url, read_timeout: 60)
          location = path || url || "io://root"
          stream.each_line do |line|
            yield line: line, source_table: nil, source_location: location, columns: []
          end
        ensure
          stream.close if stream && stream.respond_to?(:close) && io.nil?
        end
      end
    end

    def parse_row(line, format:, default_kind:, columns:)
      fields = line.split("\t", -1)
      return [nil, :malformed] if fields.length < 2

      if format.to_s == "moran_aux"
        character = fields[0].to_s.strip
        auxiliary = fields[1].to_s.strip
        return [nil, character_skip_reason(character)] unless single_character?(character)
        return [nil, :empty_code] if auxiliary.empty?

        return [{
          character: character,
          code: auxiliary,
          kind: "auxiliary",
          metadata: { "decomposition" => fields[2].to_s.strip.presence }.compact
        }, nil]
      end

      columns = Array(columns).map(&:to_s)
      text_index = columns.index("text") || 0
      code_index = columns.index("code") || 1
      return [nil, :malformed] if fields.length <= [text_index, code_index].max

      character = fields[text_index].to_s.strip
      code = fields[code_index].to_s.strip
      return [nil, character_skip_reason(character)] unless single_character?(character)
      return [nil, :empty_code] if code.empty?

      metadata = {}
      fields.each_with_index do |value, index|
        next if index == text_index || index == code_index

        value = value.to_s.strip
        next if value.empty?

        key = columns[index].presence || "column_#{index + 1}"
        metadata[key] = value
      end

      [{ character: character, code: code, kind: default_kind, metadata: metadata }, nil]
    end

    # CharacterInputCode belongs to one canonical CharacterCodepoint. RIME
    # dictionaries can also contain words/phrases; their codes are useful RIME
    # data, but assigning a phrase code to any one constituent character would
    # be false data. Count those rows explicitly instead of hiding them in one
    # undifferentiated `skipped` total.
    def character_skip_reason(text)
      return :malformed if text.to_s.empty?
      return :multi_character if text.to_s.codepoints.length > 1

      :malformed
    end

    def record_skip(result, reason:, line:, source_table:, source_location:)
      result.skipped += 1
      case reason
      when :multi_character
        result.skipped_multi_character += 1
      when :empty_code
        result.skipped_empty_code += 1
      else
        result.skipped_malformed += 1
      end

      return if result.skip_samples.length >= 8

      result.skip_samples << {
        reason: reason.to_s,
        line: line,
        source_table: source_table,
        source_location: source_location
      }.compact
    end

    def single_character?(text)
      IndexableCharacter.single?(text)
    end
  end
end
