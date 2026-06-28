#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

require "yaml"
require_relative "../config/interface_locales"

ROOT = File.expand_path("..", __dir__)
LOCALE_GLOB = File.join(ROOT, "config/locales/**/*.yml")
VIEW_GLOB = File.join(ROOT, "app/views/**/*.erb")
JAVASCRIPT_GLOB = File.join(ROOT, "app/javascript/**/*.js")
PLACEHOLDER_NAMESPACES = %w[
  common
  corpus_viewer
  home
  javascript
  pronunciations
  site
  view_options
].freeze


def deep_merge!(target, source)
  source.each do |key, value|
    if target[key].is_a?(Hash) && value.is_a?(Hash)
      deep_merge!(target[key], value)
    else
      target[key] = value
    end
  end
end


def key_present?(tree, dotted_key)
  dotted_key.split(".").reduce(tree) do |branch, part|
    break nil unless branch.is_a?(Hash) && branch.key?(part)

    branch[part]
  end
end


def flatten_leaves(tree, prefix = nil, output = {})
  tree.each do |key, value|
    path = [prefix, key].compact.join(".")
    if value.is_a?(Hash)
      flatten_leaves(value, path, output)
    else
      output[path] = value
    end
  end
  output
end


def interpolation_names(value)
  value.to_s.scan(/%\{([^}]+)\}/).flatten.sort
end

invalid_statuses = InterfaceLocales::DEFINITIONS.filter_map do |code, definition|
  status = definition[:status]
  "#{code}=#{status.inspect}" unless InterfaceLocales::VALID_STATUSES.include?(status)
end
abort "Invalid locale statuses: #{invalid_statuses.join(', ')}" if invalid_statuses.any?
abort "Source locale must be public." unless InterfaceLocales.selectable?(InterfaceLocales::SOURCE)
abort "SELECTOR_VISIBLE must be true or false." unless [true, false].include?(InterfaceLocales::SELECTOR_VISIBLE)

locale_tree = {}
locale_files = Dir.glob(LOCALE_GLOB).sort
abort "No locale files found under config/locales/." if locale_files.empty?

locale_files.each do |path|
  data = YAML.safe_load_file(path, aliases: true) || {}
  deep_merge!(locale_tree, data)
rescue Psych::SyntaxError => error
  warn "Invalid YAML: #{path}"
  warn error.message
  exit 1
end

source_code = InterfaceLocales::SOURCE.to_s
source = locale_tree.fetch(source_code) do
  abort "The source locale (#{source_code}) is missing."
end

missing_locale_roots = InterfaceLocales::ALL.map(&:to_s) - locale_tree.keys
if missing_locale_roots.any?
  warn "Missing locale roots: #{missing_locale_roots.join(', ')}"
  exit 1
end

static_keys = []
Dir.glob(VIEW_GLOB).sort.each do |path|
  File.foreach(path, encoding: "UTF-8").with_index(1) do |line, line_number|
    line.scan(/\bt\(\s*["']([^"']+)["']/) do |match|
      key = match.first
      next if key.include?('#{')

      static_keys << [path, line_number, key]
    end
  end
end

javascript_keys = []
Dir.glob(JAVASCRIPT_GLOB).sort.each do |path|
  File.foreach(path, encoding: "UTF-8").with_index(1) do |line, line_number|
    line.scan(/\bt\(\s*["']([^"']+)["']/) do |match|
      javascript_keys << [path, line_number, "javascript.#{match.first}"]
    end
  end
end

all_static_keys = static_keys + javascript_keys
missing_source = all_static_keys.reject { |(_, _, key)| key_present?(source, key) }
if missing_source.any?
  warn "Missing source-locale keys:"
  missing_source.each do |path, line_number, key|
    warn "  #{path.delete_prefix(ROOT + File::SEPARATOR)}:#{line_number}: #{key}"
  end
  exit 1
end

source_placeholders = flatten_leaves(source)
  .select { |key, _value| PLACEHOLDER_NAMESPACES.include?(key.split(".").first) }

errors = []
InterfaceLocales::ALL.each do |locale|
  next if locale == InterfaceLocales::SOURCE

  code = locale.to_s
  target_placeholders = flatten_leaves(locale_tree.fetch(code))
    .select { |key, _value| PLACEHOLDER_NAMESPACES.include?(key.split(".").first) }

  missing = source_placeholders.keys - target_placeholders.keys
  extra = target_placeholders.keys - source_placeholders.keys

  missing.sort.each { |key| errors << "#{code}: missing #{key}" }
  extra.sort.each { |key| errors << "#{code}: no English source for #{key}" }

  source_placeholders.each do |key, source_value|
    next unless target_placeholders.key?(key)

    source_names = interpolation_names(source_value)
    target_names = interpolation_names(target_placeholders.fetch(key))
    next if source_names == target_names

    errors << "#{code}: interpolation mismatch for #{key}: en=#{source_names.inspect} target=#{target_names.inspect}"
  end
end

if errors.any?
  warn "Locale catalogue validation failed:"
  errors.each { |error| warn "  #{error}" }
  exit 1
end

puts "Locale YAML parsed successfully."
puts "Checked #{static_keys.map(&:last).uniq.length} static view keys; all exist in English."
puts "Checked #{javascript_keys.map(&:last).uniq.length} static JavaScript keys; all exist in English."
puts "Checked #{source_placeholders.length} placeholder keys across #{InterfaceLocales::ALL.length} locales; catalogues match."
puts "Selector visible: #{InterfaceLocales.selector_visible?}"
puts "Selectable now: #{InterfaceLocales::SELECTABLE.join(', ')}"
puts "Staged for later: #{(InterfaceLocales::ALL - InterfaceLocales::SELECTABLE).join(', ')}"
