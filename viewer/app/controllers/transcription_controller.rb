# frozen_string_literal: true

class TranscriptionController < ApplicationController
  layout "application"

  DEFAULT_TEXT = "臣聞求木之長者必固其根本欲流之遠者必浚其泉源"

  def show
    @text = params[:text].presence || DEFAULT_TEXT
    @title = params[:title].presence || "Practice text"
    @rime_schemas = rime_schemas
    @variant_equivalents = variant_equivalents(@text)
  end

  private

  def variant_equivalents(text)
    codepoints = CharacterData::IndexableCharacter.codepoints(text).uniq
    return {} if codepoints.empty? || !defined?(VariantMapping)

    direct = VariantMapping.where(base_codepoint: codepoints).or(VariantMapping.where(variant_codepoint: codepoints)).to_a
    family_bases = (codepoints + direct.map(&:base_codepoint)).compact.uniq
    family_rows = VariantMapping.where(base_codepoint: family_bases).to_a

    families = Hash.new { |hash, key| hash[key] = [] }
    family_rows.group_by(&:base_codepoint).each do |base, rows|
      members = ([base] + rows.map(&:variant_codepoint)).compact.uniq
      members.each do |member|
        families[member].concat(members).uniq!
      end
    end

    codepoints.to_h do |codepoint|
      members = (families[codepoint].presence || [codepoint]).filter_map do |member|
        [member].pack("U") rescue nil
      end
      [[codepoint].pack("U"), members.uniq]
    end
  end

  def rime_schemas
    path = Rails.root.join("config", "rime_schemas.yml")
    return [] unless path.file?

    schemas = YAML.safe_load_file(path, aliases: false).fetch("schemas", [])
    schema_ids = schemas.filter_map { |schema| schema["schema_id"].presence }

    # The previous DISTINCT query scanned all matching CharacterInputCode rows;
    # the performance sweep measured that single query at ~8 seconds. We only
    # need a yes/no answer for a handful of configured schemas. `exists?` can
    # stop on the first matching row, and the performance migration adds an
    # index shaped for this lookup. Keeping this uncached means a fresh import is
    # visible immediately.
    available = schema_ids.select do |schema_id|
      CharacterInputCode
        .where(system_id: schema_id)
        .where.not(kind: "auxiliary")
        .exists?
    end

    schemas
      .select { |schema| available.include?(schema["schema_id"]) }
      .map { |schema| schema.merge("browser_available" => true) }
  rescue Psych::SyntaxError
    []
  end
end
