# frozen_string_literal: true

require "yaml"

class WordProcessorController < ApplicationController
  layout "application"

  def index
    @rime_schemas = RimeSchemaRegistry.available
    @function_word_groups = function_word_groups
    @script_modes = CharacterStandards.selectable_modes
    @script_mode = CharacterStandards.allowed_modes.include?(session[:script_mode].to_s.to_sym) ? session[:script_mode].to_s : "original"
    @measurement_catalogue = HistoricalMeasurements.catalogue
    @date_systems = CalendarEngine::YEAR_SYSTEMS.map { |system| { "key" => system.fetch("key"), "label" => system.fetch("label") } }
    @heavenly_stems = CalendarEngine::STEMS
    @earthly_branches = CalendarEngine::BRANCHES
  end

  def convert
    case params[:operation].to_s
    when "script"
      render json: script_conversion
    when "script_batch"
      render json: script_batch_conversion
    when "variants"
      render json: variant_suggestions
    when "date"
      render json: date_conversion
    when "era_suggestions"
      render json: era_suggestions
    when "docx_import"
      render json: docx_import
    else
      render json: { ok: false, error: "Unknown Word Processor operation." }, status: :bad_request
    end
  rescue ArgumentError => e
    render json: { ok: false, error: e.message }, status: :unprocessable_entity
  end

  private

  def script_conversion
    mode = params[:mode].to_s.to_sym
    mode = :original unless CharacterStandards.allowed_modes.include?(mode)
    {
      ok: true,
      text: CharacterStandards.convert(params[:text].to_s, mode),
      mode: mode.to_s
    }
  end

  def script_batch_conversion
    mode = params[:mode].to_s.to_sym
    mode = :original unless CharacterStandards.allowed_modes.include?(mode)
    values = Array(params[:texts]).first(50).map(&:to_s)

    {
      ok: true,
      texts: values.map { |value| CharacterStandards.convert(value, mode) },
      mode: mode.to_s
    }
  end


  def variant_suggestions
    values = Array(params[:texts]).first(20).map(&:to_s).reject(&:blank?)
    seen = values.to_h { |value| [value, true] }
    variants = []
    registry = AuthorityHanVariantRegistry.instance

    values.each do |value|
      if value.each_char.one?
        registry.forms_for(value).each do |form|
          next if seen[form]

          seen[form] = true
          variants << { text: form, source: "opencc" }
        end
      end

      CharacterStandards.selectable_modes.each do |mode|
        converted = CharacterStandards.convert(value, mode)
        next if converted.blank? || seen[converted]

        seen[converted] = true
        variants << { text: converted, source: "character_standard", mode: mode.to_s }
      end
    end

    { ok: true, variants: variants.first(50) }
  end

  def date_conversion
    input = params[:input].presence || Date.current.iso8601
    output = params[:output].presence || "chinese_modern"

    resolved = CalendarEngine.call(operation: :resolve, value: input, authority: true)
    raise ArgumentError, resolved["error"].presence || "That date could not be resolved." unless resolved["resolved"] == true
    raise ArgumentError, "That expression does not identify one absolute year." unless resolved["year"].present?

    represent_value = if resolved["month"].present? && resolved["day"].present?
      year = Integer(resolved.fetch("year"))
      month = Integer(resolved.fetch("month"))
      day = Integer(resolved.fetch("day"))
      year_text = year.negative? ? format("-%04d", year.abs) : format("%04d", year)
      format("%s-%02d-%02d", year_text, month, day)
    else
      Integer(resolved.fetch("year"))
    end

    result = CalendarEngine.call(operation: :represent, value: represent_value, include_before_epoch: true)
    raise ArgumentError, result["error"].presence || "That date cannot be represented." unless result["resolved"] == true

    text = case output
           when "sexagenary_year"
             result["sexagenary_year"]
           when "erya_year"
             result["erya_year"]
           when "chinese_modern", "gregorian", "julian", "hebrew", "islamic_tabular"
             frame = Array(result["calendar_frames"]).find { |row| row["key"] == output }
             frame && (frame["display"].presence || [frame["year"], frame["month"], frame["day"]].compact.join("-"))
           else
             row = Array(result["year_systems"]).find { |system| system["key"] == output }
             row && row["display"]
           end

    raise ArgumentError, "That date cannot be represented in the selected system." if text.blank?

    { ok: true, text: text, result: result }
  end

  def era_suggestions
    input = params[:input].presence || Date.current.iso8601
    resolved = CalendarEngine.call(operation: :resolve, value: input, authority: true)
    raise ArgumentError, resolved["error"].presence || "That date could not be resolved." unless resolved["resolved"] == true
    raise ArgumentError, "That expression does not identify one absolute year." unless resolved["year"].present?

    year = Integer(resolved.fetch("year"))
    result = EraCalendarConverter.convert(direction: "absolute_to_era", input: year.to_s)
    rows = Array(result["matches"]).filter_map do |row|
      expression = row["expression"].to_s.presence
      next unless expression

      {
        "expression" => expression,
        "name" => row["name_chn"].to_s.presence,
        "country" => row["country"].to_s.presence,
        "polity" => row["polity"].to_s.presence,
        "year_number" => row["year_number"],
        "source" => row["source"].to_s.presence
      }.compact
    end

    { ok: true, year: year, eras: rows.first(200) }
  rescue StandardError => e
    { ok: false, error: e.message, eras: [] }
  end

  def docx_import
    upload = params[:file]
    raise ArgumentError, "Choose a DOCX file to import." unless upload.respond_to?(:read) || upload.respond_to?(:tempfile)

    { ok: true, document: WordProcessorDocxImporter.call(upload) }
  end

  def function_word_groups
    path = Rails.root.join("content", "grammar", "catalogue.yml")
    return {} unless path.file?

    catalogue = YAML.safe_load(File.open(path, "r:bom|utf-8", &:read), aliases: false) || {}
    entries = Array(catalogue["entries"]).select { |entry| entry["kind"] == "function_word" && entry["headword"].present? }

    groups = Hash.new { |hash, key| hash[key] = [] }
    entries.each do |entry|
      categories = Array(entry["categories"]).presence || ["other"]
      categories.each do |category|
        groups[category] << {
          "id" => entry["id"],
          "headword" => entry["headword"],
          "importance" => entry["importance"],
          "path" => entry["path"]
        }
      end
    end

    groups.transform_values { |rows| rows.uniq { |row| row["id"] || row["headword"] } }
  rescue Psych::SyntaxError
    {}
  end
end
