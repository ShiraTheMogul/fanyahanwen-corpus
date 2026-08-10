# frozen_string_literal: true

require "yaml"
require "uri"

module CharacterData
  # Read a RIME dictionary and recursively follow import_tables. RIME often
  # uses the top-level *.dict.yaml as a manifest while keeping actual code rows
  # in sibling dictionaries.
  class RimeDictionaryReader
    class ReadError < StandardError; end

    Entry = Struct.new(:line, :source_table, :source_location, :columns, keyword_init: true)
    SAFE_TABLE_ID = /\A[A-Za-z0-9_.-]+\z/.freeze

    def initialize(path: nil, url: nil, io: nil)
      @root_path = path
      @root_url = url
      @root_io = io
    end

    def each
      return enum_for(:each) unless block_given?

      @visited = {}
      if @root_io
        read_document(io: @root_io, location: "io://root", resolver: nil) { |entry| yield entry }
      elsif @root_path && !@root_path.to_s.empty?
        read_location(path: File.expand_path(@root_path)) { |entry| yield entry }
      elsif @root_url && !@root_url.to_s.empty?
        read_location(url: @root_url) { |entry| yield entry }
      else
        raise ArgumentError, "provide path, url, or io"
      end
    end

    private

    def read_location(path: nil, url: nil, &block)
      location = path || url
      return if @visited[location]

      @visited[location] = true
      stream = Utf8Stream.open(path: path, url: url, read_timeout: 60)
      resolver = if path
                   ->(table) { { path: sibling_path(path, table) } }
                 else
                   ->(table) { { url: sibling_url(url, table) } }
                 end
      read_document(io: stream, location: location, resolver: resolver, &block)
    ensure
      stream.close if stream&.respond_to?(:close)
    end

    def read_document(io:, location:, resolver:)
      header_lines = []
      in_header = false
      header_complete = false
      header = {}
      table_name = table_name_from(location)
      columns = []
      headerless_lines = []

      io.each_line do |line|
        stripped = line.to_s.delete_prefix("\uFEFF").chomp

        if !in_header && !header_complete && stripped.strip == "---"
          in_header = true
          headerless_lines.clear
          next
        end

        if in_header
          if stripped.strip == "..."
            in_header = false
            header_complete = true
            header = parse_header(header_lines, location)
            table_name = present_string(header["name"]) || table_name_from(location)
            columns = Array(header["columns"]).map(&:to_s)
          else
            header_lines << line
          end
          next
        end

        if header_complete
          yield Entry.new(line: stripped, source_table: table_name, source_location: location, columns: columns)
        elsif !(stripped.empty? || stripped.lstrip.start_with?("#"))
          # Keep only headerless input until EOF. Official RIME dictionaries use
          # a YAML header; this fallback supports small custom two-column tables.
          headerless_lines << stripped
        end
      end

      raise ReadError, "unterminated RIME YAML header in #{location}" if in_header

      unless header_complete
        headerless_lines.each do |line|
          yield Entry.new(line: line, source_table: table_name, source_location: location, columns: [])
        end
        return
      end

      Array(header["import_tables"]).each do |table|
        table = table.to_s.strip
        validate_table_id!(table)
        unless resolver
          raise ReadError, "#{location} imports #{table.inspect}, but imports cannot be resolved from an anonymous IO"
        end

        read_location(**resolver.call(table)) { |entry| yield entry }
      end
    end

    def parse_header(lines, location)
      return {} if lines.empty?

      value = YAML.safe_load(lines.join, permitted_classes: [], permitted_symbols: [], aliases: false)
      value.is_a?(Hash) ? value : {}
    rescue Psych::Exception => error
      raise ReadError, "invalid RIME YAML header in #{location}: #{error.message}"
    end

    def validate_table_id!(table)
      if table.empty? || !table.match?(SAFE_TABLE_ID) || table == "." || table == ".." || table.include?("..")
        raise ReadError, "unsafe RIME import_tables entry: #{table.inspect}"
      end
    end

    def sibling_path(path, table)
      File.expand_path("#{table}.dict.yaml", File.dirname(path))
    end

    def sibling_url(url, table)
      URI.join(url, "#{table}.dict.yaml").to_s
    rescue URI::InvalidURIError => error
      raise ReadError, "cannot resolve RIME import #{table.inspect} from #{url}: #{error.message}"
    end

    def table_name_from(location)
      File.basename(location.to_s).sub(/\.dict\.yaml\z/, "")
    end

    def present_string(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end
  end
end
