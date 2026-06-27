#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

require "yaml"
require "fileutils"
require_relative "../config/interface_locales"

ROOT = File.expand_path("..", __dir__)
SOURCE_DIR = File.join(ROOT, "config/locales", InterfaceLocales::SOURCE.to_s)
MANAGED_SEPARATELY = %w[pronunciation_data.yml].freeze
PLACEHOLDER_WARNING = "# PLACEHOLDER CATALOGUE: translate values only; do not rename keys."


def deep_fill_missing(target, source)
  target = {} unless target.is_a?(Hash)

  source.each do |key, value|
    if !target.key?(key)
      target[key] = Marshal.load(Marshal.dump(value))
    elsif value.is_a?(Hash)
      target[key] = deep_fill_missing(target[key], value)
    end
  end

  target
end


def write_yaml(path, locale, body)
  yaml = YAML.dump({ locale => body }).sub(/\A---\s*\n/, "")
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, "#{PLACEHOLDER_WARNING}\n#{yaml}", encoding: "UTF-8")
end

source_files = Dir.glob(File.join(SOURCE_DIR, "*.yml")).sort
abort "No English source files found in #{SOURCE_DIR}." if source_files.empty?

updated = 0

InterfaceLocales::ALL.each do |locale|
  next if locale == InterfaceLocales::SOURCE

  code = locale.to_s
  source_files.each do |source_path|
    filename = File.basename(source_path)
    next if MANAGED_SEPARATELY.include?(filename)

    source_data = YAML.safe_load_file(source_path, aliases: true) || {}
    source_body = source_data.fetch(InterfaceLocales::SOURCE.to_s)

    target_path = File.join(ROOT, "config/locales", code, filename)
    target_data = File.exist?(target_path) ? (YAML.safe_load_file(target_path, aliases: true) || {}) : {}
    target_body = target_data.fetch(code, {})

    write_yaml(target_path, code, deep_fill_missing(target_body, source_body))
    updated += 1
  end
end

puts "Synchronized missing interface placeholders in #{updated} locale files."
puts "Pronunciation data is managed by script/rebuild_pronunciation_locale_catalogues.rb."
