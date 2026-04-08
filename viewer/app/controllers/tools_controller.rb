# frozen_string_literal: true

require "csv"

class ToolsController < ApplicationController
  EXTRACTOR_OPTIONS = [
    ["Cangjie input", "cangjie"],
    ["Unicode definition (Unihan)", "unicode_definition"],
    ["Kangxi dictionary entry", "kangxi_entry"],
    ["Mandarin reading", "mandarin"],
    ["Cantonese reading", "cantonese"],
    ["Japanese on reading", "japanese_on"],
    ["Korean reading", "korean"],
    ["Vietnamese reading", "vietnamese"],
    ["Common readings (Mandarin, Cantonese, Japanese on, Korean, Vietnamese)", "common_readings"]
  ].freeze

  def index; end

  # --- Lunar calendar converter ------------------------------------------
  def lunar
    date, warning = parse_western_date(
      input: params[:input].to_s,
      date_iso: params[:date_iso].to_s
    )

    if date.nil?
      return render partial: "tools/tool_output",
                    locals: { frame_id: "lunar_out", output: "Could not parse a date." },
                    status: :bad_request
    end

    lunar = LunarCalendar.at_lunar(date.year, date.month, date.day) # solar -> lunar

    out = []
    out << "Solar: #{date.iso8601}"
    out << "Lunar: #{format_lunar(lunar)}"
    out << "Note:  #{warning}" if warning.present?

    render partial: "tools/tool_output",
           locals: { frame_id: "lunar_out", output: out.join("\n") }
  rescue StandardError => e
    render partial: "tools/tool_output",
           locals: { frame_id: "lunar_out", output: "Error: #{e.class}: #{e.message}" },
           status: :unprocessable_entity
  end

  # --- Phoneticisation converter (Mandarin + Cantonese) -------------------
  #
  # Mandarin uses pinyin-rb via your Phoneticization::Converters wrapper.
  # Cantonese uses pingyam-rb via the same wrapper.
def phonetic_mandarin
  input = params[:input].to_s
  from  = (params[:from].presence || "pinyin_numbers").to_s.downcase.to_sym
  to    = (params[:to].presence   || "pinyin_diacritics").to_s.downcase.to_sym

  allowed = [:original] + Phoneticization::Converters::MANDARIN_SCHEMES.keys
  unless allowed.include?(from) && allowed.include?(to)
    return render partial: "tools/tool_output",
                  locals: { frame_id: "mandarin_out", output: "Allowed: #{allowed.sort.join(", ")}" },
                  status: :bad_request
  end

  output = (from == :original) ? input : Phoneticization::Converters.mandarin(input, from: from, to: to, fail_silently: false)
  render partial: "tools/tool_output", locals: { frame_id: "mandarin_out", output: output }
end

def phonetic_cantonese
  input = params[:input].to_s
  from  = (params[:from].presence || "jyutping").to_s.downcase.to_sym
  to    = (params[:to].presence   || "ipa").to_s.downcase.to_sym

  allowed = [:original] + Phoneticization::Converters::CANTONESE_SCHEMES.keys
  unless allowed.include?(from) && allowed.include?(to)
    return render partial: "tools/tool_output",
                  locals: { frame_id: "cantonese_out", output: "Allowed: #{allowed.sort.join(", ")}" },
                  status: :bad_request
  end

  output = (from == :original) ? input : Phoneticization::Converters.cantonese(input, from: from, to: to, fail_silently: false)
  render partial: "tools/tool_output", locals: { frame_id: "cantonese_out", output: output }
end

  # --- Character property extractor --------------------------------------
  def cangjie
    raw = params[:input].to_s.strip
    return render partial: "tools/cangjie_output",
                  locals: { char: nil, codepoint: nil, lines: [], message: "No input." },
                  status: :bad_request if raw.empty?

    extractor_key = params[:extract].presence || "cangjie"
    config = extractor_config_for(extractor_key)

    # If user pastes Cangjie letters, just show the mapping (no HKCards image).
    if extractor_key == "cangjie" && raw.match?(/\A[A-Za-z]+\z/)
      latin = CangjieKeymap.normalise_cangjie(raw)
      han   = CangjieKeymap.latin_to_han(latin)
      return render partial: "tools/cangjie_output",
                    locals: {
                      char: nil, codepoint: nil,
                      lines: ["Latin: #{latin}", "Han:   #{han}"],
                      message: "Input looks like Cangjie letters (no character lookup)."
                    }
    end

    cps_in_text = extract_han_codepoints(raw)
    if cps_in_text.empty?
      return render partial: "tools/tool_output",
                    locals: { frame_id: "cangjie_out", output: "No Han characters found in the input." },
                    status: :bad_request
    end

    unique_cps = []
    seen = {}
    cps_in_text.each do |cp|
      next if seen[cp]
      seen[cp] = true
      unique_cps << cp
    end

    ccs = CharacterCodepoint.where(codepoint: unique_cps).to_a
    cc_by_cp = ccs.index_by(&:codepoint)

    props = CharacterProperty.where(character_codepoint_id: ccs.map(&:id), field: config[:fields])
                             .order(:field, :source, :value)
                             .to_a
    props_by_ccid = props.group_by(&:character_codepoint_id)

    rows = unique_cps.map do |cp|
      cc = cc_by_cp[cp]
      grouped = Hash.new { |h, k| h[k] = [] }

      if cc
        (props_by_ccid[cc.id] || []).each do |prop|
          grouped[prop.field] << normalize_property_entry(prop)
        end
        grouped.each_value do |entries|
          entries.uniq! { |entry| [entry[:value], entry[:source]] }
        end
      end

      {
        char: [cp].pack("U"),
        codepoint: cp,
        found_in_db: cc.present?,
        values_by_field: grouped
      }
    end

    if params[:download].to_s == "csv"
      csv = build_property_csv(rows: rows, config: config)
      filename = "character_extract_#{extractor_key}_#{Time.current.strftime('%Y%m%d_%H%M%S')}.csv"
      return send_data csv, filename: filename, type: "text/csv; charset=utf-8", disposition: "attachment"
    end

    show_hkcards = params[:hkcards].to_s == "1"

    if extractor_key == "cangjie" && rows.length == 1
      row = rows.first
      lines = row[:values_by_field]["kCangjie"].presence&.map do |entry|
        "#{entry[:value]} — #{entry[:source]}"
      end || ["No kCangjie property found for this character."]

      return render partial: "tools/cangjie_output",
                    locals: { char: row[:char], codepoint: row[:codepoint], lines: lines, message: nil }
    end

    if extractor_key == "cangjie" && show_hkcards
      hk_rows = rows.map do |row|
        entries = row[:values_by_field]["kCangjie"] || []
        codes = entries.map do |entry|
          { latin: entry[:latin], han: entry[:han], source: entry[:source].to_s }
        end

        row.merge(codes: codes)
      end

      return render partial: "tools/cangjie_table_output",
                    locals: { rows: hk_rows, message: nil }
    end

    field_columns = config[:fields].map do |field|
      {
        field: field,
        label: pretty_field_label(field)
      }
    end

    render partial: "tools/property_extract_output",
           locals: {
             extractor_label: config[:label],
             rows: rows,
             field_columns: field_columns,
             message: nil
           }
  end

  private

  # --- Helpers ------------------------------------------------------------

  def allowed_schemes_for(lang)
    case lang
    when "mandarin"
      [:original] + Phoneticization::Converters::MANDARIN_SCHEMES.keys
    when "cantonese"
      [:original] + Phoneticization::Converters::CANTONESE_SCHEMES.keys
    else
      []
    end
  end

  def default_from_for(lang)
    case lang
    when "mandarin" then "pinyin_numbers"
    when "cantonese" then "jyutping"
    else "original"
    end
  end

  def default_to_for(lang)
    case lang
    when "mandarin" then "pinyin_diacritics"
    when "cantonese" then "jyutping"
    else "original"
    end
  end

  def extractor_options
    EXTRACTOR_OPTIONS
  end
  helper_method :extractor_options

  def extractor_config_for(key)
    configs = {
      "cangjie" => {
        key: "cangjie",
        label: "Cangjie input",
        fields: ["kCangjie"]
      },
      "unicode_definition" => {
        key: "unicode_definition",
        label: "Unicode definition (Unihan)",
        fields: ["kDefinition"]
      },
      "kangxi_entry" => {
        key: "kangxi_entry",
        label: "Kangxi dictionary entry",
        fields: ["kangxi_gloss"]
      },
      "mandarin" => {
        key: "mandarin",
        label: "Mandarin reading",
        fields: ["kMandarin"]
      },
      "cantonese" => {
        key: "cantonese",
        label: "Cantonese reading",
        fields: ["kCantonese"]
      },
      "japanese_on" => {
        key: "japanese_on",
        label: "Japanese on reading",
        fields: ["kJapaneseOn"]
      },
      "korean" => {
        key: "korean",
        label: "Korean reading",
        fields: ["kKorean"]
      },
      "vietnamese" => {
        key: "vietnamese",
        label: "Vietnamese reading",
        fields: ["kVietnamese"]
      },
      "common_readings" => {
        key: "common_readings",
        label: "Common readings",
        fields: %w[kMandarin kCantonese kJapaneseOn kKorean kVietnamese]
      }
    }

    configs[key] || configs["cangjie"]
  end

  def extract_han_codepoints(raw)
    if raw.match?(/\AU\+[0-9A-Fa-f]+\z/) || raw.match?(/\A[0-9A-Fa-f]+\z/)
      cp = parse_codepoint(raw)
      return cp.nil? ? [] : [cp]
    end

    raw.each_codepoint.each_with_object([]) do |cp, acc|
      next if [9, 10, 13, 32].include?(cp)
      next unless UnicodeRanges.han?(cp)

      acc << cp
    end
  end

  def normalize_property_entry(prop)
    value = prop.value.to_s.strip

    if prop.field == "kCangjie"
      latin = CangjieKeymap.normalise_cangjie(value)
      han = CangjieKeymap.latin_to_han(latin)
      {
        value: "#{han} (#{latin})",
        source: prop.source.to_s,
        latin: latin,
        han: han
      }
    else
      {
        value: value,
        source: prop.source.to_s
      }
    end
  end

  def pretty_field_label(field)
    labels = {
      "kCangjie" => "Cangjie",
      "kDefinition" => "Unicode definition",
      "kangxi_gloss" => "Kangxi entry",
      "kMandarin" => "Mandarin",
      "kCantonese" => "Cantonese",
      "kJapaneseOn" => "Japanese on",
      "kKorean" => "Korean",
      "kVietnamese" => "Vietnamese"
    }

    labels[field] || field
  end

  def build_property_csv(rows:, config:)
    CSV.generate do |csv|
      headers = ["Character", "Codepoint"]

      config[:fields].each do |field|
        headers << pretty_field_label(field)
        headers << "#{pretty_field_label(field)} sources"
      end

      csv << headers

      rows.each do |row|
        line = [row[:char], "U+#{row[:codepoint].to_i.to_s(16).upcase}"]

        config[:fields].each do |field|
          entries = row[:values_by_field][field] || []
          line << entries.map { |entry| entry[:value] }.join(" | ")
          line << entries.map { |entry| entry[:source] }.reject(&:blank?).uniq.join(" | ")
        end

        csv << line
      end
    end
  end

  # Accept: "U+8BF4", "8BF4", or a literal character like "说"
  def parse_codepoint(raw)
    s = raw.to_s.strip
    return nil if s.empty?

    if s.match?(/\AU\+[0-9A-Fa-f]+\z/)
      s.delete_prefix("U+").to_i(16)
    elsif s.match?(/\A[0-9A-Fa-f]+\z/)
      s.to_i(16)
    else
      s.ord
    end
  rescue StandardError
    nil
  end

  # Prefer date picker param if present; fall back to free text.
  def parse_western_date(input:, date_iso:)
    s = (date_iso.presence || input).to_s.strip
    return [nil, nil] if s.empty?

    down = s.downcase
    return [Date.current, nil] if %w[today now].include?(down)
    return [Date.yesterday, nil] if down == "yesterday"
    return [Date.tomorrow, nil] if down == "tomorrow"

    # YYYY-MM-DD / YYYY/MM/DD / YYYY.MM.DD
    if (m = s.match(/\A(\d{4})[\/\-.](\d{1,2})[\/\-.](\d{1,2})\z/))
      y, mo, d = m.captures.map(&:to_i)
      return [Date.new(y, mo, d), nil]
    end

    # DD/MM/YYYY or MM/DD/YYYY (UK default when ambiguous)
    if (m = s.match(/\A(\d{1,2})[\/\-.](\d{1,2})[\/\-.](\d{2}|\d{4})\z/))
      a = m[1].to_i
      b = m[2].to_i
      y = m[3].to_i
      y += (y <= 68 ? 2000 : 1900) if y < 100

      if a > 12 && b <= 12
        return [Date.new(y, b, a), nil]
      elsif b > 12 && a <= 12
        return [Date.new(y, a, b), "Interpreted as MM/DD/YYYY because the middle number exceeds 12."]
      else
        return [Date.new(y, b, a), "Ambiguous numeric date; interpreted as DD/MM/YYYY (UK default)."]
      end
    end

    # Named months etc.
    if s.match?(/[A-Za-z]/)
      return [Date.parse(s), nil]
    end

    [nil, nil]
  rescue ArgumentError
    [nil, nil]
  end

  def format_lunar(l)
    era  = l.respond_to?(:chinese_era) ? "#{l.chinese_era}年 " : ""
    leap = (l.respond_to?(:leap?) && l.leap?) ? "閏" : ""
    month = "#{Zhengshu.format(l.month, use_you: true)}月"
    day   = "#{Zhengshu.format(l.day, use_you: true)}日"
    "#{era}#{leap}#{month}#{day}"
  end
end
