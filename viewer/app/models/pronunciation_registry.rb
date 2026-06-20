# frozen_string_literal: true

require "yaml"

# One source of truth for pronunciation fields.
#
# FieldLens, dictionary sections, ruby selectors and pronunciation lookups use
# this registry instead of maintaining separate case statements. Hand-written
# entries live in config/pronunciations.yml. Bulk datasets may add reviewed
# entries in config/pronunciation_datasets.yml.
module PronunciationRegistry
  BASE_CONFIG_PATH = Rails.root.join("config", "pronunciations.yml")
  DATASET_CONFIG_PATH = Rails.root.join("config", "pronunciation_datasets.yml")
  NAMESPACED_FIELD = /\Areading\.(?<family>[a-z0-9_]+)\.(?<variety>[a-z0-9_]+)\.(?<notation>[a-z0-9_]+)\z/.freeze

  module_function

  def reload!
    @config = nil
    @families = nil
    @fields = nil
    @ruby_sources = nil
    @ruby_source_groups = nil
  end

  def families
    @families ||= begin
      raw = config.fetch("families", {})
      raw.map do |key, value|
        {
          key: key.to_s,
          label: value.fetch("label", humanize_key(key)),
          order: value.fetch("order", 999).to_i,
          default_open: !!value["default_open"]
        }
      end.sort_by { |family| [family[:order], family[:label]] }
    end
  end

  def family(key)
    families.find { |candidate| candidate[:key] == key.to_s }
  end

  def fields
    @fields ||= begin
      base = config.fetch("fields", {})
      datasets = dataset_config.fetch("fields", {})
      base.merge(datasets).transform_keys(&:to_s)
    end
  end

  def field_metadata(field)
    name = field.to_s
    exact = fields[name]
    return normalize_field_metadata(name, exact) if exact

    namespaced_field_metadata(name)
  end

  def pronunciation_field?(field)
    field_metadata(field).present?
  end

  def family_key_for(field)
    field_metadata(field)&.fetch(:family, nil)
  end

  def label_for_field(field)
    field_metadata(field)&.fetch(:label, nil)
  end

  def order_for_field(field)
    field_metadata(field)&.fetch(:order, 999) || 999
  end

  def pronunciation_sections(props)
    rows = Array(props)
    known = Hash.new { |hash, key| hash[key] = [] }
    unknown = []

    rows.each do |prop|
      metadata = field_metadata(prop.field)
      if metadata
        known[metadata[:family]] << [prop, metadata]
      else
        unknown << prop
      end
    end

    sections = families.filter_map do |family_meta|
      entries = known.delete(family_meta[:key]) || []
      next if entries.empty?

      direct = entries.select { |_prop, meta| meta[:variety_key].blank? }
      varieties = entries
        .reject { |_prop, meta| meta[:variety_key].blank? }
        .group_by { |_prop, meta| meta[:variety_key] }
        .map do |variety_key, grouped|
          first_meta = grouped.first.last
          {
            key: variety_key,
            label: display_variety_label(first_meta),
            props: sort_property_pairs(grouped).map(&:first)
          }
        end
        .sort_by { |variety| variety[:label].to_s }

      {
        key: family_meta[:key],
        label: family_meta[:label],
        default_open: family_meta[:default_open],
        props: sort_property_pairs(direct).map(&:first),
        varieties: varieties,
        count: entries.length
      }
    end

    # A namespaced field with a family missing from the family list should not
    # disappear. Keep it visible under Other so the configuration error is
    # obvious rather than silently hiding data.
    known.each_value do |entries|
      unknown.concat(entries.map(&:first))
    end

    if unknown.any?
      sections << {
        key: "other",
        label: "Other",
        default_open: false,
        props: unknown.sort_by { |prop| [prop.field.to_s, prop.source.to_s, prop.value.to_s] },
        varieties: [],
        count: unknown.length
      }
    end

    sections
  end

  def ruby_sources
    @ruby_sources ||= fields.filter_map do |field, value|
      ruby = value["ruby"]
      next unless ruby.is_a?(Hash)
      next if ruby["key"].blank?

      metadata = field_metadata(field) || {}
      {
        key: ruby.fetch("key").to_s.to_sym,
        label: ruby["label_en"].to_s.presence || ruby.fetch("label", humanize_key(ruby.fetch("key"))),
        field: field,
        sources: Array(ruby["sources"]).map(&:to_s).freeze,
        special: ruby["special"]&.to_s&.to_sym,
        formatter: ruby.fetch("formatter", "raw").to_s.to_sym,
        order: ruby.fetch("order", 999).to_i,
        family: metadata[:family],
        family_label: family(metadata[:family])&.fetch(:label, nil),
        variety_key: metadata[:variety_key],
        variety_label: metadata[:variety_label],
        variety_label_en: metadata[:variety_label_en],
        notation: metadata[:notation]
      }
    end.sort_by { |entry| [entry[:order], entry[:label]] }.freeze
  end

  # The viewer is currently English-first. Keep the original Chinese label in
  # the registry, but prefer the reviewed/generated English label for display.
  # A future locale switch only needs to change this one method.
  def display_variety_label(metadata)
    metadata[:variety_label_en].to_s.presence ||
      metadata[:variety_label].to_s.presence ||
      humanize_key(metadata[:variety_key])
  end

  def ruby_source_keys
    ruby_sources.map { |entry| entry[:key] }
  end

  def ruby_source_options
    ruby_sources.map { |entry| [entry[:label], entry[:key]] }
  end

  # Family -> reading-system data for the two-stage ruby selector. The stored
  # preference remains the stable ruby source key; family is only a UI filter.
  def ruby_source_groups
    @ruby_source_groups ||= families.filter_map do |family_meta|
      sources = ruby_sources
        .select { |entry| entry[:family] == family_meta[:key] }
        .map do |entry|
          {
            key: entry[:key].to_s,
            label: entry[:label].to_s,
            variety_label: display_variety_label(entry),
            variety_label_en: entry[:variety_label_en].to_s.presence,
            notation: entry[:notation].to_s.presence
          }
        end

      next if sources.empty?

      {
        key: family_meta[:key],
        label: family_meta[:label],
        sources: sources
      }
    end
  end

  def ruby_family_for_source(key)
    ruby_source(key)&.fetch(:family, nil)
  end

  def ruby_source(key)
    normalized = key.to_s.strip.downcase.tr(" ", "_").to_sym
    ruby_sources.find { |entry| entry[:key] == normalized }
  end

  def namespaced_field_metadata(field)
    match = NAMESPACED_FIELD.match(field)
    return nil unless match

    family_key = match[:family]
    return nil unless family(family_key)

    notation = match[:notation]
    {
      field: field,
      family: family_key,
      label: notation_label(notation),
      order: 999,
      variety_key: match[:variety],
      variety_label: humanize_key(match[:variety]),
      notation: notation,
      dynamic: true
    }
  end
  private_class_method :namespaced_field_metadata

  def normalize_field_metadata(field, value)
    {
      field: field,
      family: value.fetch("family").to_s,
      label: value.fetch("label", humanize_key(field)),
      order: value.fetch("order", 999).to_i,
      variety_key: value["variety_key"]&.to_s,
      variety_label: value["variety_label"] || value["variety"]&.to_s,
      variety_label_en: value["variety_label_en"]&.to_s,
      notation: value["notation"]&.to_s,
      source_dataset: value["source_dataset"]&.to_s,
      source_archive: value["source_archive"]&.to_s,
      dynamic: false
    }.tap do |metadata|
      if metadata[:variety_key].present? && metadata[:variety_label].blank?
        metadata[:variety_label] = humanize_key(metadata[:variety_key])
      end
    end
  end
  private_class_method :normalize_field_metadata

  def sort_property_pairs(pairs)
    pairs.sort_by do |prop, metadata|
      [metadata[:order], prop.field.to_s, prop.source.to_s, prop.value.to_s]
    end
  end
  private_class_method :sort_property_pairs

  def config
    @config ||= load_yaml(BASE_CONFIG_PATH)
  end
  private_class_method :config

  def dataset_config
    load_yaml(DATASET_CONFIG_PATH)
  end
  private_class_method :dataset_config

  def load_yaml(path)
    return {} unless path.exist?

    YAML.safe_load_file(path, aliases: false) || {}
  end
  private_class_method :load_yaml

  def humanize_key(value)
    value.to_s.tr("_", " ").split.map(&:capitalize).join(" ")
  end
  private_class_method :humanize_key

  def notation_label(value)
    case value.to_s
    when "ipa" then "IPA"
    when "romanisation", "romanization" then "Romanisation"
    when "native_script" then "Native script"
    else humanize_key(value)
    end
  end
  private_class_method :notation_label
end
