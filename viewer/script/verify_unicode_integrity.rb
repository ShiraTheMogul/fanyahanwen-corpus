#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

require "json"
require "pathname"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

class UnicodeIntegrityVerifier
  TEXT_EXTENSIONS = %w[.css .csv .erb .js .json .md .rb .txt .yaml .yml].freeze
  REQUIRED_LABELS = %w[中國漢文 商殷朝 清朝 日本漢文 江戸時代 朝鮮漢文 越南漢文].freeze

  # These are characteristic products of UTF-8 bytes being decoded as CP437,
  # Windows-1252, or Latin-1. Build them from code points so the verifier does
  # not flag its own source code.
  MOJIBAKE_MARKERS = [
    [0xFFFD],
    [0x00EF, 0x00BF, 0x00BD],
    [0x00E2, 0x20AC, 0x2122],
    [0x00E2, 0x20AC, 0x0153],
    [0x00E2, 0x20AC, 0x009D],
    [0x03A3, 0x2555],
    [0x03C3, 0x00A3],
    [0x00B5, 0x255A],
    [0x00B5, 0x00A3],
    [0x00B5, 0x00FB],
    [0x0398, 0x00A1],
    [0x03A6, 0x00D1],
    [0x2555, 0x00A1],
    [0x2563, 0x0398]
  ].map { |codepoints| codepoints.pack("U*") }.freeze

  def initialize(root, all: false)
    @root = Pathname.new(root).expand_path
    @all = all
    @errors = []
    @checked_paths = 0
    @checked_text_files = 0
  end

  def run
    raise "Directory does not exist: #{@root}" unless @root.directory?

    scan_paths
    scan_text_files
    check_known_labels
    check_atlas_references

    if @errors.any?
      warn "UNICODE INTEGRITY CHECK FAILED"
      @errors.each { |error| warn "- #{error}" }
      exit 1
    end

    puts "UNICODE INTEGRITY CHECK PASSED"
    puts "Paths checked:      #{@checked_paths}"
    puts "Text files checked: #{@checked_text_files}"
  end

  private

  def scan_paths
    each_path do |path|
      @checked_paths += 1
      relative = relative_path(path)
      check_string(relative, "path")
    end
  end

  def scan_text_files
    each_path do |path|
      next unless path.file?
      next unless TEXT_EXTENSIONS.include?(path.extname.downcase)

      @checked_text_files += 1
      bytes = path.binread
      text = bytes.dup.force_encoding(Encoding::UTF_8)
      unless text.valid_encoding?
        @errors << "Invalid UTF-8 bytes in #{relative_path(path)}"
        next
      end
      check_string(text, "contents of #{relative_path(path)}")
    end
  end

  def check_known_labels
    hierarchy = @root.join("content", "atlas", "hierarchy.json")
    return unless hierarchy.file?

    text = strict_utf8_read(hierarchy)
    REQUIRED_LABELS.each do |label|
      @errors << "Known label missing from hierarchy.json: #{label}" unless text.include?(label)
    end
  end

  def check_atlas_references
    hierarchy_path = @root.join("content", "atlas", "hierarchy.json")
    polities_root = @root.join("content", "atlas", "polities")
    return unless hierarchy_path.file? && polities_root.directory?

    hierarchy = JSON.parse(strict_utf8_read(hierarchy_path))
    entry_ids = []
    walk = lambda do |nodes|
      Array(nodes).each do |node|
        entry_ids << node["entry_id"] if node.is_a?(Hash) && node["entry_id"]
        walk.call(node["children"]) if node.is_a?(Hash)
      end
    end
    walk.call(hierarchy.fetch("roots"))

    metadata_ids = Dir.glob(polities_root.join("**", "metadata.json").to_s, File::FNM_DOTMATCH).map do |filename|
      data = JSON.parse(strict_utf8_read(Pathname.new(filename)))
      data.fetch("id")
    end

    missing_metadata = entry_ids - metadata_ids
    orphan_metadata = metadata_ids - entry_ids
    @errors << "Hierarchy entries missing metadata: #{missing_metadata.join(', ')}" if missing_metadata.any?
    @errors << "Metadata not registered in hierarchy: #{orphan_metadata.join(', ')}" if orphan_metadata.any?
  rescue JSON::ParserError, KeyError => error
    @errors << "Atlas JSON validation failed: #{error.message}"
  end

  def check_string(value, location)
    text = value.to_s
    unless text.encoding == Encoding::UTF_8 || text.ascii_only?
      text = text.encode(Encoding::UTF_8)
    end
    unless text.valid_encoding?
      @errors << "Invalid UTF-8 in #{location}"
      return
    end

    MOJIBAKE_MARKERS.each do |marker|
      @errors << "Mojibake marker #{marker.inspect} found in #{location}" if text.include?(marker)
    end
  rescue EncodingError => error
    @errors << "Encoding failure in #{location}: #{error.message}"
  end

  def strict_utf8_read(path)
    bytes = path.binread
    text = bytes.force_encoding(Encoding::UTF_8)
    raise EncodingError, "invalid UTF-8 in #{relative_path(path)}" unless text.valid_encoding?
    text
  end

  def each_path
    paths = if @all
              [@root, *glob_tree(@root)]
            else
              scoped_paths
            end

    paths.uniq.sort_by(&:to_s).each { |path| yield path }
  end

  def scoped_paths
    paths = []
    tree_roots = [
      @root.join("content", "atlas"),
      @root.join("app", "services", "atlas"),
      @root.join("app", "views", "atlas")
    ]
    tree_roots.each do |tree|
      next unless tree.exist?
      paths << tree
      paths.concat(glob_tree(tree))
    end

    files = [
      "ATLAS_INTEGRATION_REPORT.md",
      "ATLAS_ROUTES_TO_ADD.txt",
      "app/controllers/atlas_controller.rb",
      "app/helpers/atlas_helper.rb",
      "app/javascript/controllers/atlas_submission_controller.js",
      "config/locales/en/atlas.yml",
      "docs/atlas_articles.md",
      "script/atlas_integration_smoke.rb",
      "script/generate_atlas_from_corpus.rb",
      "script/verify_unicode_integrity.rb"
    ]
    files.each do |relative|
      path = @root.join(relative)
      paths << path if path.exist?
    end
    paths
  end

  def glob_tree(tree)
    Dir.glob(tree.join("**", "*").to_s, File::FNM_DOTMATCH).filter_map do |filename|
      path = Pathname.new(filename)
      next if [".", ".."].include?(path.basename.to_s)
      path
    end
  end

  def relative_path(path)
    path.relative_path_from(@root).to_s.encode(Encoding::UTF_8)
  end
end

all = ARGV.delete("--all")
root = ARGV.fetch(0, Pathname.new(__dir__).join("..").expand_path.to_s)
UnicodeIntegrityVerifier.new(root, all: !!all).run
