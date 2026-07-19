# frozen_string_literal: true

require "date"
require "pathname"
require "yaml"

module AtlasFrontMatterVerifier
  module_function

  def verify!(root = Pathname.pwd, io: $stdout)
    root = Pathname.new(root).expand_path
    paths = Dir.glob(root.join("content", "atlas", "entries", "**", "*.md").to_s).sort.map { |path| Pathname.new(path) }
    errors = []

    paths.each do |path|
      begin
        raw = path.binread.force_encoding(Encoding::UTF_8)
        raise "not valid UTF-8" unless raw.valid_encoding?

        parse_front_matter!(raw)
      rescue StandardError => error
        relative = path.relative_path_from(root)
        errors << "#{relative}: #{error.class}: #{error.message}"
      end
    end

    unless errors.empty?
      raise <<~MESSAGE
        Atlas front-matter verification failed:
        #{errors.map { |error| "  - #{error}" }.join("\n")}
      MESSAGE
    end

    io.puts "Atlas front-matter verification passed (#{paths.length} Markdown files)."
    true
  end

  def parse_front_matter!(text)
    return {} unless text.start_with?("---\n", "---\r\n")

    lines = text.lines
    closing_index = lines.each_index.drop(1).find { |index| lines[index].strip == "---" }
    raise ArgumentError, "unclosed YAML front matter" unless closing_index

    parsed = YAML.safe_load(
      lines[1...closing_index].join,
      permitted_classes: [Date, Time],
      permitted_symbols: [],
      aliases: false
    )

    unless parsed.nil? || parsed.is_a?(Hash)
      raise ArgumentError, "front matter must be a key/value mapping"
    end

    parsed || {}
  end
end

if $PROGRAM_NAME == __FILE__
  root = ARGV.fetch(0, Pathname.new(__dir__).join("..").expand_path.to_s)
  AtlasFrontMatterVerifier.verify!(root)
end
