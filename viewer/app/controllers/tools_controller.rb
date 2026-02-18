# frozen_string_literal: true

class ToolsController < ApplicationController
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

  # --- Cangjie lookup (HKCards + latin + Han shapes) ----------------------
  def cangjie
    raw = params[:input].to_s.strip
    return render partial: "tools/cangjie_output",
                  locals: { char: nil, codepoint: nil, lines: [], message: "No input." },
                  status: :bad_request if raw.empty?

    # If user pastes Cangjie letters, just show the mapping (no HKCards image).
    if raw.match?(/\A[A-Za-z]+\z/)
      latin = CangjieKeymap.normalise_cangjie(raw)
      han   = CangjieKeymap.latin_to_han(latin)
      return render partial: "tools/cangjie_output",
                    locals: {
                      char: nil, codepoint: nil,
                      lines: ["Latin: #{latin}", "Han:   #{han}"],
                      message: "Input looks like Cangjie letters (no character lookup)."
                    }
    end

    # Codepoint literal mode: "U+8BF4" or "8BF4" should behave like a single-character lookup.
    if raw.match?(/\AU\+[0-9A-Fa-f]+\z/) || raw.match?(/\A[0-9A-Fa-f]+\z/)
      cp = parse_codepoint(raw)
      return render partial: "tools/cangjie_output",
                    locals: { char: nil, codepoint: nil, lines: [], message: "Could not parse a character/codepoint." },
                    status: :bad_request if cp.nil?
      cps_in_text = [cp]
    else
      cps_in_text = []
      raw.each_codepoint do |cp|
        # Skip whitespace, but keep punctuation.
        next if [9, 10, 13, 32].include?(cp)
        cps_in_text << cp
      end
    end

    # Single-character mode (keep the existing, nicer card output).
    if cps_in_text.length == 1
      cp = cps_in_text.first
      cc = CharacterCodepoint.find_by(codepoint: cp)
      return render partial: "tools/cangjie_output",
                    locals: { char: [cp].pack("U"), codepoint: cp, lines: [], message: "Not found in DB." },
                    status: :not_found if cc.nil?

      props = CharacterProperty.where(character_codepoint_id: cc.id, field: "kCangjie")
                               .order(:source, :value)

      lines =
        if props.empty?
          ["No kCangjie property found for this character."]
        else
          props.map do |p|
            latin = CangjieKeymap.normalise_cangjie(p.value.to_s)
            han   = CangjieKeymap.latin_to_han(latin)
            "#{latin} (#{han}) — #{p.source}"
          end
        end

      return render partial: "tools/cangjie_output",
                    locals: { char: cc.chr, codepoint: cc.codepoint, lines: lines, message: nil }
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

    props = CharacterProperty.where(character_codepoint_id: ccs.map(&:id), field: "kCangjie")
                             .order(:source, :value)
                             .to_a
    props_by_ccid = props.group_by(&:character_codepoint_id)

    rows = unique_cps.map do |cp|
      cc = cc_by_cp[cp]
      pps = cc ? (props_by_ccid[cc.id] || []) : []

      codes = pps.map do |p|
        latin = CangjieKeymap.normalise_cangjie(p.value.to_s)
        han   = CangjieKeymap.latin_to_han(latin)
        { latin: latin, han: han, source: p.source.to_s }
      end

      # De-dup within a character (sometimes sources repeat the same code).
      codes = codes.uniq { |c| c[:latin] }

      {
        char: [cp].pack("U"),
        codepoint: cp,
        found_in_db: cc.present?,
        codes: codes
      }
    end

    show_hkcards = params[:hkcards].to_s == "1"

    if show_hkcards
      render partial: "tools/cangjie_table_output",
             locals: { rows: rows, message: nil }
    else
      lines = rows.map do |r|
        if r[:codes].empty?
          "* #{r[:char]}: (no Cangjie code)"
        else
          combos = r[:codes].map { |c| "#{c[:han]} (#{c[:latin]})" }.join(" / ")
          "* #{r[:char]}: #{combos}"
        end
      end

      render partial: "tools/cangjie_list_output",
             locals: { lines: lines, message: nil }
    end
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
