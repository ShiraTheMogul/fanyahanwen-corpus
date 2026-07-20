#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

require "json"
require "pathname"
require "zlib"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

class UnicodeIntegrityVerifier
  TEXT_EXTENSIONS = %w[.css .csv .erb .js .json .md .rb .txt .yaml .yml].freeze
  REQUIRED_LABELS = %w[中國 商殷朝 清朝 日本 江戸時代 朝鮮 越南 琉球].freeze

  MOJIBAKE_MARKERS = [
    [0xFFFD],
    [0x00E4, 0x00B8],
    [0x00E5, 0x0153],
    [0x00E6, 0x0153],
    [0x00E6, 0x00BC],
    [0x00E6, 0x2013],
    [0x00B5, 0x00A3, 0x00D8, 0x00DA]
  ].map { |codepoints| codepoints.pack("U*") }.freeze

  def initialize(root)
    @root = Pathname.new(root).expand_path
    @errors = []
    @checked_paths = 0
    @checked_text_files = 0
  end

  def run
    raise "Directory does not exist: #{@root}" unless @root.directory?

    each_path do |path|
      @checked_paths += 1
      check_string(relative_path(path), "path")
      check_text_file(path) if path.file? && TEXT_EXTENSIONS.include?(path.extname.downcase)
    end
    check_catalogue_labels

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

  def each_path
    roots = [
      @root.join("content", "atlas"),
      @root.join("app", "controllers", "atlas_controller.rb"),
      @root.join("app", "helpers", "atlas_helper.rb"),
      @root.join("app", "services", "atlas"),
      @root.join("app", "views", "atlas"),
      @root.join("app", "assets", "stylesheets", "atlas.css"),
      @root.join("config", "locales", "en", "atlas.yml"),
      @root.join("lib", "tasks", "atlas.rake"),
      @root.join("script", "atlas_integration_smoke.rb"),
      @root.join("script", "atlas_catalogue_smoke.rb"),
      @root.join("script", "verify_unicode_integrity.rb"),
      @root.join("script", "verify_atlas_front_matter.rb"),
      @root.join("script", "verify_shang_atlas_articles.rb"),
      @root.join("script", "rewrite_shang_atlas_articles.rb")
    ]

    roots.each do |root|
      next unless root.exist?

      yield root
      next unless root.directory?

      Dir.glob(root.join("**", "*").to_s, File::FNM_DOTMATCH).sort.each do |filename|
        path = Pathname.new(filename)
        next if [".", ".."].include?(path.basename.to_s)
        yield path
      end
    end
  end

  def check_text_file(path)
    @checked_text_files += 1
    bytes = path.binread
    text = bytes.force_encoding(Encoding::UTF_8)
    unless text.valid_encoding?
      @errors << "Invalid UTF-8 bytes in #{relative_path(path)}"
      return
    end

    check_string(text, relative_path(path))
  rescue Errno::ENOENT, Errno::EACCES => e
    @errors << "Could not read #{relative_path(path)}: #{e.class}: #{e.message}"
  end

  def check_string(value, context)
    text = value.to_s.dup.force_encoding(Encoding::UTF_8)
    unless text.valid_encoding?
      @errors << "Invalid UTF-8 in #{context}"
      return
    end

    marker = MOJIBAKE_MARKERS.find { |candidate| text.include?(candidate) }
    @errors << "Mojibake marker #{marker.inspect} in #{context}" if marker
  end

  def check_catalogue_labels
    periodisation_path = @root.join("content", "atlas", "periodisation.json")
    catalogue_path = @root.join("storage", "corpus_search", "atlas", "catalogue-v4.json.gz")

    texts = []
    texts << periodisation_path.read(encoding: "UTF-8") if periodisation_path.file?

    if catalogue_path.file?
      raw = Zlib::GzipReader.open(catalogue_path.to_s, &:read).force_encoding(Encoding::UTF_8)
      unless raw.valid_encoding?
        @errors << "Atlas runtime catalogue is not valid UTF-8"
        return
      end

      check_string(raw, relative_path(catalogue_path))
      texts << raw

      payload = JSON.parse(raw)
      @errors << "Atlas catalogue version is not 4" unless payload["version"].to_i == 4
      @errors << "Atlas catalogue has no entries" unless payload["entries"].is_a?(Array) && payload["entries"].any?
    else
      @errors << "Atlas runtime catalogue is missing; run bin/rails atlas:rebuild_catalogue"
    end

    text = texts.join("\n")
    REQUIRED_LABELS.each do |label|
      @errors << "Known label missing from atlas data: #{label}" unless text.include?(label)
    end
  rescue JSON::ParserError => e
    @errors << "Atlas catalogue JSON is invalid: #{e.message}"
  rescue Zlib::GzipFile::Error, Zlib::Error => e
    @errors << "Atlas catalogue gzip is invalid: #{e.message}"
  end

  def relative_path(path)
    path.relative_path_from(@root).to_s.encode(Encoding::UTF_8)
  rescue ArgumentError
    path.to_s.encode(Encoding::UTF_8)
  end
end

root = ARGV.fetch(0, Pathname.new(__dir__).join("..").expand_path.to_s)
UnicodeIntegrityVerifier.new(root).run
