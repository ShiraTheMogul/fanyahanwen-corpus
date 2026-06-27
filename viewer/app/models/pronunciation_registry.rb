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
    metadata = field_metadata(field)
    return nil unless metadata

    I18n.t(
      "pronunciations.fields.#{translation_key_segment(metadata[:field])}.label",
      default: metadata[:label]
    )
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

      # Every registered pronunciation belongs inside a second-level reading
      # group. For living lects this is normally a variety (Shanghai, Shuri,
      # Cantonese); for older material it can be a historical system or
      # reconstruction (Guangyun, Menggu Ziyun, Baxter-Sagart 2014).
      #
      # A field without explicit group metadata still receives its own safe
      # dropdown instead of leaking back into a long, flat family-level list.
      varieties = entries
        .group_by { |_prop, meta| display_group_key(meta) }
        .map do |group_key, grouped|
          first_meta = grouped.first.last
          {
            key: group_key,
            label: display_group_label(first_meta),
            location: display_location_label(first_meta),
            references: first_meta[:references],
            order: grouped.map { |_prop, meta| meta[:order].to_i }.min,
            props: sort_property_pairs(grouped).map(&:first)
          }
        end
        .sort_by { |group| [group[:order], group[:label].to_s] }

      {
        key: family_meta[:key],
        label: display_family_label(family_meta),
        default_open: family_meta[:default_open],
        props: [],
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
        label: I18n.t("pronunciations.families.other", default: "Other"),
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
        # Keep both source labels. Presentation chooses between them per locale;
        # the registry data itself remains locale-neutral and reusable.
        label: ruby["label_en"].to_s.presence || ruby.fetch("label", humanize_key(ruby.fetch("key"))),
        label_en: ruby["label_en"]&.to_s,
        label_original: ruby.fetch("label", humanize_key(ruby.fetch("key"))).to_s,
        field: field,
        sources: Array(ruby["sources"]).map(&:to_s).freeze,
        special: ruby["special"]&.to_s&.to_sym,
        formatter: ruby.fetch("formatter", "raw").to_s.to_sym,
        order: ruby.fetch("order", 999).to_i,
        family: metadata[:family],
        family_label: family(metadata[:family])&.fetch(:label, nil),
        group_key: metadata[:group_key],
        group_label: metadata[:group_label],
        group_label_en: metadata[:group_label_en],
        variety_key: metadata[:variety_key],
        variety_label: metadata[:variety_label],
        variety_label_en: metadata[:variety_label_en],
        notation: metadata[:notation]
      }
    end.sort_by { |entry| [entry[:order], entry[:label]] }.freeze
  end

  # A display group is the second-level dropdown below a language family.
  # It may be a geographic variety, a prestige variety, a historical source,
  # or a scholarly reconstruction. Explicit group metadata wins; existing
  # variety metadata remains fully supported for bulk topolect datasets.
  def display_group_key(metadata)
    metadata[:group_key].to_s.presence ||
      metadata[:variety_key].to_s.presence ||
      metadata[:field].to_s
  end

  def display_group_label(metadata)
    fallback = default_group_label(metadata)
    translation_key = group_translation_key(metadata)
    return fallback unless translation_key

    I18n.t("#{translation_key}.label", default: fallback)
  end

  # Imported topolect records retain a reviewed English name and the canonical
  # Chinese name used in the source data. Locale catalogues copy those values:
  # English receives the English name, while Literary Chinese receives the same
  # Chinese name verbatim. Other staged locales begin with the English value as
  # an explicit placeholder for future human translation.
  def display_variety_label(metadata)
    fallback = default_variety_label(metadata)
    translation_key = group_translation_key(metadata)
    return fallback unless translation_key

    I18n.t("#{translation_key}.label", default: fallback)
  end

  def display_location_label(metadata)
    fallback = default_location_label(metadata)
    return nil if fallback.blank?

    translation_key = group_translation_key(metadata)
    return fallback unless translation_key

    I18n.t("#{translation_key}.location", default: fallback)
  end

  def display_family_label(metadata)
    I18n.t("pronunciations.families.#{metadata[:key]}", default: metadata[:label])
  end

  def display_ruby_source_label(entry)
    fallback = if literary_chinese_locale?
      entry[:label_original].to_s.presence || entry[:label_en].to_s.presence || entry[:label].to_s
    else
      entry[:label_en].to_s.presence || entry[:label].to_s.presence || entry[:label_original].to_s
    end

    key = translation_key_segment(entry[:key])
    I18n.t("pronunciations.ruby_sources.#{key}.label", default: fallback)
  end


  # Split a configured suffix annotation from a stored pronunciation value.
  # The value remains one database string (for example ?ee1), while the view
  # can mark only the final "1" with a hover label such as "Accent class".
  def value_annotation_for(field, value)
    metadata = field_metadata(field)
    annotation = metadata&.fetch(:value_annotation, nil)
    return nil unless annotation

    pattern = annotation[:suffix_pattern].to_s
    return nil if pattern.empty?

    match = Regexp.new("\\A(?<base>.*?)(?<annotation>#{pattern})\\z").match(value.to_s)
    return nil unless match

    {
      base: match[:base],
      annotation: match[:annotation],
      label: I18n.t(
        "pronunciations.fields.#{translation_key_segment(metadata[:field])}.value_annotation",
        default: annotation[:label]
      )
    }
  rescue RegexpError
    nil
  end

  def ruby_source_keys
    ruby_sources.map { |entry| entry[:key] }
  end

  def ruby_source_options
    ruby_sources.map { |entry| [display_ruby_source_label(entry), entry[:key]] }
  end

  # Family -> reading-system data for the two-stage ruby selector. The stored
  # preference remains the stable ruby source key; family is only a UI filter.
  def ruby_source_groups
    locale = I18n.locale.to_s
    @ruby_source_groups ||= {}
    @ruby_source_groups[locale] ||= families.filter_map do |family_meta|
      sources = ruby_sources
        .select { |entry| entry[:family] == family_meta[:key] }
        .map do |entry|
          {
            key: entry[:key].to_s,
            label: display_ruby_source_label(entry),
            variety_label: display_group_label(entry),
            variety_label_en: entry[:variety_label_en].to_s.presence,
            notation: entry[:notation].to_s.presence
          }
        end

      next if sources.empty?

      {
        key: family_meta[:key],
        label: display_family_label(family_meta),
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

  def literary_chinese_locale?
    I18n.locale.to_s == "lzh"
  end


  def default_group_label(metadata)
    if literary_chinese_locale?
      metadata[:group_label].to_s.presence ||
        metadata[:variety_label].to_s.presence ||
        metadata[:group_label_en].to_s.presence ||
        metadata[:variety_label_en].to_s.presence ||
        metadata[:label].to_s.presence ||
        humanize_key(display_group_key(metadata))
    else
      metadata[:group_label_en].to_s.presence ||
        metadata[:variety_label_en].to_s.presence ||
        metadata[:group_label].to_s.presence ||
        metadata[:variety_label].to_s.presence ||
        metadata[:label].to_s.presence ||
        humanize_key(display_group_key(metadata))
    end
  end
  private_class_method :default_group_label

  def default_variety_label(metadata)
    if literary_chinese_locale?
      metadata[:variety_label].to_s.presence ||
        metadata[:variety_label_en].to_s.presence ||
        humanize_key(metadata[:variety_key])
    else
      metadata[:variety_label_en].to_s.presence ||
        metadata[:variety_label].to_s.presence ||
        humanize_key(metadata[:variety_key])
    end
  end
  private_class_method :default_variety_label

  def default_location_label(metadata)
    if literary_chinese_locale?
      metadata[:location].to_s.presence || metadata[:location_en].to_s.presence
    else
      metadata[:location_en].to_s.presence || metadata[:location].to_s.presence
    end
  end
  private_class_method :default_location_label

  def group_translation_key(metadata)
    family = metadata[:family].to_s
    group = display_group_key(metadata).to_s
    return nil if family.blank? || group.blank?

    "pronunciations.groups.#{translation_key_segment(family)}.#{translation_key_segment(group)}"
  end
  private_class_method :group_translation_key

  def translation_key_segment(value)
    value.to_s.gsub(/[^A-Za-z0-9_]+/, "_").gsub(/\A_+|_+\z/, "").downcase.presence || "unnamed"
  end
  private_class_method :translation_key_segment

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
      group_key: value["group_key"]&.to_s,
      group_label: value["group_label"]&.to_s,
      group_label_en: value["group_label_en"]&.to_s,
      variety_key: value["variety_key"]&.to_s,
      variety_label: value["variety_label"] || value["variety"]&.to_s,
      variety_label_en: value["variety_label_en"]&.to_s,
      notation: value["notation"]&.to_s,
      source_dataset: value["source_dataset"]&.to_s,
      source_archive: value["source_archive"]&.to_s,
      location: value["location"]&.to_s,
      location_en: value["location_en"]&.to_s,
      references: normalize_references(value["references"]),
      value_annotation: normalize_value_annotation(value["value_annotation"]),
      dynamic: false
    }.tap do |metadata|
      if metadata[:variety_key].present? && metadata[:variety_label].blank?
        metadata[:variety_label] = humanize_key(metadata[:variety_key])
      end
    end
  end
  private_class_method :normalize_field_metadata


  def normalize_value_annotation(value)
    return nil unless value.is_a?(Hash)

    label = value["label"].to_s.strip
    suffix_pattern = value["suffix_pattern"].to_s.strip
    return nil if label.empty? || suffix_pattern.empty?

    { label: label, suffix_pattern: suffix_pattern }
  end
  private_class_method :normalize_value_annotation

  def normalize_references(value)
    Array(value).filter_map do |reference|
      next unless reference.is_a?(Hash)

      citation = reference["citation"].to_s.strip
      next if citation.empty?

      {
        label: reference["label"].to_s.strip.presence,
        citation: citation,
        url: reference["url"].to_s.strip.presence,
        license: reference["license"].to_s.strip.presence,
        license_url: reference["license_url"].to_s.strip.presence
      }
    end
  end
  private_class_method :normalize_references

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
