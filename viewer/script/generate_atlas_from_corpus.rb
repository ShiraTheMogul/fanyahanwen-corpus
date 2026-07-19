#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "time"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

# Adds newly discovered historical folders to the committed atlas hierarchy.
# It only descends beneath nodes explicitly marked with
# `discover_children_as`; it never guesses that an arbitrary work folder is a
# polity.
class AtlasFolderGenerator
  Options = Struct.new(:apply, :corpus_root, :viewer_root, keyword_init: true)

  def initialize(options)
    @options = options
    @viewer_root = Pathname.new(options.viewer_root).expand_path
    @corpus_root = Pathname.new(options.corpus_root).expand_path
    @atlas_root = @viewer_root.join("content", "atlas")
    @hierarchy_path = @atlas_root.join("hierarchy.json")
    @hierarchy = JSON.parse(strict_utf8_read(@hierarchy_path))
    @created_nodes = []
    @created_metadata = []
    @existing_metadata = []
    @missing_folders = []
    @errors = []
  end

  def run
    validate_inputs!
    puts "Fanya Hanwen atlas folder generator"
    puts "Mode:      #{@options.apply ? 'APPLY' : 'DRY RUN'}"
    puts "Viewer:    #{@viewer_root}"
    puts "Corpus:    #{@corpus_root}"
    puts "Hierarchy: #{@hierarchy_path}"

    validate_unicode_tree!
    walk_nodes(@hierarchy.fetch("roots"))
    write_hierarchy if @options.apply && @created_nodes.any?
    write_report
    print_summary
    exit 1 if @errors.any?
  end

  private

  def validate_inputs!
    raise "Viewer root is missing config/application.rb" unless @viewer_root.join("config", "application.rb").file?
    raise "Corpus root is not a directory: #{@corpus_root}" unless @corpus_root.directory?
    raise "Atlas hierarchy is missing: #{@hierarchy_path}" unless @hierarchy_path.file?
    raise "Atlas hierarchy roots must be a list" unless @hierarchy["roots"].is_a?(Array)
  end

  def walk_nodes(nodes)
    Array(nodes).each do |node|
      unless node.is_a?(Hash)
        @errors << "Hierarchy child is not a mapping"
        next
      end

      verify_registered_folder(node)
      discover_children(node) if node["discover_children_as"].to_s != ""
      walk_nodes(node["children"])
    end
  end

  def verify_registered_folder(node)
    path = node["path"].to_s
    return if path.empty?

    folder = corpus_folder(path)
    @missing_folders << path unless folder.directory?
  end

  def discover_children(node)
    parent_path = node.fetch("path")
    parent_folder = corpus_folder(parent_path)
    return unless parent_folder.directory?

    children = Array(node["children"])
    known = children.filter_map { |child| child.is_a?(Hash) ? child["path"].to_s : nil }.to_h { |path| [path, true] }
    child_kind = node.fetch("discover_children_as")

    folder_names = Dir.children(parent_folder.to_s, encoding: Encoding::UTF_8).sort
    folder_names.each do |name|
      folder = parent_folder.join(name)
      next unless folder.directory?
      historical_path = "#{parent_path}/#{name}"
      next if known[historical_path]

      new_node = {
        "path" => historical_path,
        "label" => name,
        "kind" => child_kind,
        "descendant_directory_count" => descendant_directory_count(folder),
        "children" => []
      }

      if child_kind == "polity"
        metadata = default_metadata(historical_path, name)
        new_node["entry_id"] = metadata.fetch("id")
        create_metadata(metadata)
      end

      children << new_node
      @created_nodes << historical_path
      known[historical_path] = true
      puts "NEW NODE: #{historical_path}"
    end

    node["children"] = children
  end

  def create_metadata(metadata)
    target = @atlas_root.join(metadata.fetch("article_path")).dirname.join("metadata.json")
    if target.file?
      @existing_metadata << target.relative_path_from(@viewer_root).to_s
      return
    end

    @created_metadata << target.relative_path_from(@viewer_root).to_s
    return unless @options.apply

    FileUtils.mkdir_p(target.dirname)
    atomic_write(target, JSON.pretty_generate(metadata) + "\n")
  end

  def default_metadata(historical_path, name)
    pieces = historical_path.split("/")
    root = pieces.first
    period = pieces.length >= 3 ? pieces[1] : nil
    {
      "id" => historical_path.gsub("/", "--"),
      "kind" => "polity",
      "name" => { "display" => name, "hanzi" => name, "alt" => [] },
      "timespan" => {
        "start_year" => nil,
        "end_year" => nil,
        "ongoing" => false,
        "start_approx" => false,
        "end_approx" => false
      },
      "locations" => { "capital" => [], "territory_note" => "" },
      "notable_authors" => [],
      "notable_works" => [],
      "related" => [],
      "corpus" => {
        "root" => root,
        "periods" => [period].compact,
        "polity" => name,
        "paths" => [corpus_relative_path(historical_path)]
      },
      "placements" => [historical_path],
      "article_path" => "polities/#{historical_path}/index.md",
      "notes" => ""
    }
  end

  def write_hierarchy
    atomic_write(@hierarchy_path, JSON.pretty_generate(@hierarchy) + "\n")
  end

  def write_report
    timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%S%6NZ")
    report_root = @viewer_root.join("tmp", "atlas_generation", timestamp)
    FileUtils.mkdir_p(report_root)

    write_csv(report_root.join("created_nodes.csv"), "path", @created_nodes)
    write_csv(report_root.join("created_metadata.csv"), "path", @created_metadata)
    write_csv(report_root.join("existing_metadata.csv"), "path", @existing_metadata)
    write_csv(report_root.join("missing_registered_folders.csv"), "path", @missing_folders)
    write_csv(report_root.join("errors.csv"), "message", @errors)

    summary = {
      "mode" => @options.apply ? "apply" : "dry_run",
      "created_nodes" => @created_nodes.length,
      "created_metadata" => @created_metadata.length,
      "existing_metadata" => @existing_metadata.length,
      "missing_registered_folders" => @missing_folders.length,
      "errors" => @errors.length
    }
    report_root.join("summary.json").write(JSON.pretty_generate(summary) + "\n")
    puts "Report:    #{report_root}"
  end

  def print_summary
    puts
    puts "Created hierarchy nodes: #{@created_nodes.length}"
    puts "Created metadata files:  #{@created_metadata.length}"
    puts "Existing metadata files: #{@existing_metadata.length}"
    puts "Missing registered paths: #{@missing_folders.length}"
    puts "Errors:                  #{@errors.length}"
    puts(@options.apply ? "Changes applied." : "Dry run only; no hierarchy or metadata was changed.")
  end

  def corpus_folder(historical_path)
    @corpus_root.join(corpus_relative_path(historical_path))
  end

  def corpus_relative_path(historical_path)
    pieces = historical_path.split("/")
    [pieces.first, "clean", *pieces.drop(1)].join("/")
  end

  def descendant_directory_count(folder)
    pattern = folder.join("**", "*").to_s
    Dir.glob(pattern, File::FNM_DOTMATCH).count { |path| File.directory?(path) }
  rescue SystemCallError => e
    @errors << "Could not count #{folder}: #{e.message}"
    0
  end

  def atomic_write(path, content)
    temporary = path.sub_ext("#{path.extname}.tmp-#{Process.pid}")
    encoded = content.to_s.encode(Encoding::UTF_8, invalid: :raise, undef: :raise)
    raise EncodingError, "Generated content is not valid UTF-8 for #{path}" unless encoded.valid_encoding?
    temporary.binwrite(encoded)
    File.rename(temporary, path)
  ensure
    temporary&.delete if temporary&.exist?
  end

  def strict_utf8_read(path)
    bytes = path.binread
    text = bytes.force_encoding(Encoding::UTF_8)
    raise EncodingError, "Invalid UTF-8 in #{path}" unless text.valid_encoding?
    text
  end

  def validate_unicode_tree!
    strings = []
    collect_strings = lambda do |value|
      case value
      when Hash
        value.each do |key, child|
          strings << key.to_s
          collect_strings.call(child)
        end
      when Array
        value.each { |child| collect_strings.call(child) }
      when String
        strings << value
      end
    end
    collect_strings.call(@hierarchy)

    invalid = strings.reject { |value| value.encoding == Encoding::UTF_8 && value.valid_encoding? }
    raise EncodingError, "Hierarchy contains invalid UTF-8 strings" if invalid.any?

    required = %w[中國漢文 商殷朝 清朝 日本漢文 江戸時代 朝鮮漢文 越南漢文]
    labels = strings.to_h { |value| [value, true] }
    missing = required.reject { |value| labels[value] }
    raise EncodingError, "Hierarchy lost known Unicode labels: #{missing.join(', ')}" if missing.any?
  end

  def write_csv(path, heading, rows)
    CSV.open(path, "w:UTF-8", write_headers: true, headers: [heading]) do |csv|
      rows.each { |value| csv << [value] }
    end
  end
end

viewer_root = Pathname.new(__dir__).join("..").expand_path
default_corpus = if viewer_root.join("corpus").directory?
                   viewer_root.join("corpus")
                 else
                   viewer_root.parent.join("corpus")
                 end
options = AtlasFolderGenerator::Options.new(
  apply: false,
  viewer_root: viewer_root,
  corpus_root: default_corpus
)

OptionParser.new do |parser|
  parser.banner = "Usage: ruby script/generate_atlas_from_corpus.rb [--dry-run|--apply] [--corpus PATH]"
  parser.on("--dry-run", "Report changes without writing hierarchy or metadata (default)") { options.apply = false }
  parser.on("--apply", "Create new hierarchy nodes and metadata files") { options.apply = true }
  parser.on("--corpus PATH", "Path containing the corpus roots") { |value| options.corpus_root = Pathname.new(value) }
  parser.on("--viewer PATH", "Viewer root; normally inferred from the script location") { |value| options.viewer_root = Pathname.new(value) }
end.parse!

AtlasFolderGenerator.new(options).run
