#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

require "yaml"
require "fileutils"
require_relative "../config/interface_locales"

ROOT = File.expand_path("..", __dir__)
BASE_PATH = File.join(ROOT, "config/pronunciations.yml")
DATASET_PATH = File.join(ROOT, "config/pronunciation_datasets.yml")
OUTPUT_NAME = "pronunciation_data.yml"
PLACEHOLDER_WARNING = "# PLACEHOLDER CATALOGUE: translate values only; do not rename keys."

# These Sinitic interface locales start from the canonical Chinese labels stored
# in the pronunciation registry. Human translations may still override any value.
ORIGINAL_LABEL_LOCALES = %i[lzh yue nan wuu cjy hak hsn gan czh cnp csp].freeze


def key_segment(value)
  cleaned = value.to_s.gsub(/[^A-Za-z0-9_]+/, "_").gsub(/\A_+|_+\z/, "").downcase
  cleaned.empty? ? "unnamed" : cleaned
end


def humanize(value)
  value.to_s.tr("_", " ").split.map(&:capitalize).join(" ")
end


def deep_overlay(defaults, existing)
  result = Marshal.load(Marshal.dump(defaults))
  return result unless existing.is_a?(Hash)

  existing.each do |key, value|
    result[key] = if result[key].is_a?(Hash) && value.is_a?(Hash)
      deep_overlay(result[key], value)
    else
      value
    end
  end

  result
end


def build_catalogue(fields, original:)
  output = {
    "pronunciations" => {
      "fields" => {},
      "groups" => {},
      "ruby_sources" => {}
    }
  }

  fields.each do |field, value|
    field_key = key_segment(field)
    field_label = if original
      value["label"].to_s.empty? ? humanize(field) : value["label"].to_s
    else
      value["label_en"].to_s.empty? ? (value["label"].to_s.empty? ? humanize(field) : value["label"].to_s) : value["label_en"].to_s
    end

    field_entry = { "label" => field_label }
    annotation = value["value_annotation"]
    if annotation.is_a?(Hash) && !annotation["label"].to_s.strip.empty?
      field_entry["value_annotation"] = annotation["label"].to_s.strip
    end
    output["pronunciations"]["fields"][field_key] = field_entry

    family = key_segment(value["family"] || "other")
    raw_group = value["group_key"] || value["variety_key"] || field
    group_key = key_segment(raw_group)

    group_label = if original
      value["group_label"] || value["variety_label"] || value["group_label_en"] || value["variety_label_en"] || value["label"] || humanize(raw_group)
    else
      value["group_label_en"] || value["group_label"] || value["variety_label_en"] || value["variety_label"] || value["label"] || humanize(raw_group)
    end

    location = if original
      value["location"] || value["location_en"]
    else
      value["location_en"] || value["location"]
    end

    family_groups = output["pronunciations"]["groups"][family] ||= {}
    group_entry = family_groups[group_key] ||= { "label" => group_label.to_s }
    group_entry["location"] = location.to_s if location && !group_entry.key?("location")

    ruby_data = value["ruby"]
    next unless ruby_data.is_a?(Hash) && !ruby_data["key"].to_s.empty?

    ruby_key = key_segment(ruby_data["key"])
    ruby_label = if original
      ruby_data["label"] || ruby_data["label_en"] || humanize(ruby_data["key"])
    else
      ruby_data["label_en"] || ruby_data["label"] || humanize(ruby_data["key"])
    end

    output["pronunciations"]["ruby_sources"][ruby_key] = { "label" => ruby_label.to_s }
  end

  output
end


def write_yaml(path, locale, body, comment: nil)
  yaml = YAML.dump({ locale => body }).sub(/\A---\s*\n/, "")
  FileUtils.mkdir_p(File.dirname(path))
  prefix = comment ? "#{comment}\n" : ""
  File.write(path, "#{prefix}#{yaml}", encoding: "UTF-8")
end

base = YAML.safe_load_file(BASE_PATH, aliases: false) || {}
datasets = YAML.safe_load_file(DATASET_PATH, aliases: false) || {}
fields = base.fetch("fields", {}).merge(datasets.fetch("fields", {}))

english_defaults = build_catalogue(fields, original: false)
original_defaults = build_catalogue(fields, original: true)

InterfaceLocales::ALL.each do |locale|
  code = locale.to_s
  path = File.join(ROOT, "config/locales", code, OUTPUT_NAME)

  defaults = ORIGINAL_LABEL_LOCALES.include?(locale) ? original_defaults : english_defaults
  existing_data = File.exist?(path) ? (YAML.safe_load_file(path, aliases: true) || {}) : {}
  existing_body = existing_data.fetch(code, {})

  body = locale == InterfaceLocales::SOURCE ? defaults : deep_overlay(defaults, existing_body)
  comment = locale == InterfaceLocales::SOURCE ? nil : PLACEHOLDER_WARNING
  write_yaml(path, code, body, comment: comment)
end

puts "Rebuilt pronunciation locale catalogues for #{InterfaceLocales::ALL.length} locales."
puts "Fields: #{english_defaults.dig('pronunciations', 'fields').length}"
puts "Groups: #{english_defaults.dig('pronunciations', 'groups').sum { |_family, groups| groups.length }}"
puts "Ruby sources: #{english_defaults.dig('pronunciations', 'ruby_sources').length}"
