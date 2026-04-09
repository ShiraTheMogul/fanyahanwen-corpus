# frozen_string_literal: true

require "csv"

class ToolsController < ApplicationController
  EXTRACTOR_OPTIONS = [
    ["Cangjie input", "cangjie"],
    ["Unicode definition (Unihan)", "unicode_definition"],
    ["Kangxi dictionary entry", "kangxi_entry"],
    ["Shuowen entry", "shuowen_entry"],
    ["Guangyun definition", "guangyun_definition"],
    ["Guangyun fanqie", "guangyun_fanqie"],
    ["Guangyun rhyme", "guangyun_rhyme"],
    ["Guangyun tone", "guangyun_tone"],
    ["Mandarin reading", "mandarin"],
    ["Cantonese reading", "cantonese"],
    ["Japanese on reading", "japanese_on"],
    ["Korean reading", "korean"],
    ["Vietnamese reading", "vietnamese"],
    ["Common readings (Mandarin, Cantonese, Japanese on, Korean, Vietnamese)", "common_readings"]
  ].freeze

  EXTRACT_FIELD_CONFIGS = {
    "unicode_definition" => {
      label: "Unicode definition (Unihan)",
      columns: [{ field: "kDefinition", label: "Unicode definition" }]
    },
    "kangxi_entry" => {
      label: "Kangxi dictionary entry",
      columns: [{ field: "kangxi_gloss", label: "Kangxi definition" }]
    },
    "shuowen_entry" => {
      label: "Shuowen entry",
      columns: [{ field: "shuowen_entry", label: "Shuowen entry" }]
    },
    "guangyun_definition" => {
      label: "Guangyun definition",
      columns: [{ field: "guangyun_definition", label: "Guangyun definition" }]
    },
    "guangyun_fanqie" => {
      label: "Guangyun fanqie",
      columns: [{ field: "guangyun_fanqie", label: "Guangyun fanqie" }]
    },
    "guangyun_rhyme" => {
      label: "Guangyun rhyme",
      columns: [{ field: "guangyun_rhyme", label: "Guangyun rhyme" }]
    },
    "guangyun_tone" => {
      label: "Guangyun tone",
      columns: [{ field: "guangyun_tone", label: "Guangyun tone" }]
    },
    "mandarin" => {
      label: "Mandarin reading",
      columns: [{ field: "kMandarin", label: "Mandarin" }]
    },
    "cantonese" => {
      label: "Cantonese reading",
      columns: [{ field: "kCantonese", label: "Cantonese" }]
    },
    "japanese_on" => {
      label: "Japanese on reading",
      columns: [{ field: "kJapaneseOn", label: "Japanese on" }]
    },
    "korean" => {
      label: "Korean reading",
      columns: [
        { field: "kKorean", label: "Korean (Yale)" },
        { field: "kHangul", label: "Korean (Hangul)" }
      ]
    },
    "vietnamese" => {
      label: "Vietnamese reading",
      columns: [{ field: "kVietnamese", label: "Vietnamese" }]
    },
    "common_readings" => {
      label: "Common readings",
      columns: [
        { field: "kMandarin", label: "Mandarin" },
        { field: "kCantonese", label: "Cantonese" },
        { field: "kJapaneseOn", label: "Japanese on" },
        { field: "kKorean", label: "Korean (Yale)" },
        { field: "kHangul", label: "Korean (Hangul)" },
        { field: "kVietnamese", label: "Vietnamese" }
      ]
    }
  }.freeze

  ENRICHABLE_FIELD_OPTIONS = {
    "kangxi_gloss" => "Kangxi definition",
    "kDefinition" => "Unicode definition",
    "shuowen_entry" => "Shuowen entry",
    "guangyun_definition" => "Guangyun definition",
    "guangyun_fanqie" => "Guangyun fanqie",
    "guangyun_rhyme" => "Guangyun rhyme",
    "guangyun_tone" => "Guangyun tone",
    "kMandarin" => "Mandarin",
    "kCantonese" => "Cantonese",
    "kJapaneseOn" => "Japanese on",
    "kKorean" => "Korean (Yale)",
    "kHangul" => "Korean (Hangul)",
    "kVietnamese" => "Vietnamese"
  }.freeze

  def index
    @extractor_options = EXTRACTOR_OPTIONS
    @enrichable_field_options = ENRICHABLE_FIELD_OPTIONS
  end

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

    lunar = LunarCalendar.at_lunar(date.year, date.month, date.day)

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

  # --- Character data extractor / Anki enricher --------------------------
  def cangjie
    return handle_anki_enrich if params[:mode].to_s == "anki_enrich"

    raw = params[:input].to_s.strip
    return render partial: "tools/cangjie_output",
                  locals: { char: nil, codepoint: nil, lines: [], message: "No input." },
                  status: :bad_request if raw.empty?

    extractor_key = params[:extract].presence || "cangjie"
    return handle_cangjie_only(raw) if extractor_key == "cangjie"

    config = EXTRACT_FIELD_CONFIGS[extractor_key]
    unless config
      return render partial: "tools/tool_output",
                    locals: { frame_id: "cangjie_out", output: "Unknown extractor." },
                    status: :bad_request
    end

    cps_in_text = extract_han_codepoints(raw)
    if cps_in_text.empty?
      return render partial: "tools/tool_output",
                    locals: { frame_id: "cangjie_out", output: "No Han characters found." },
                    status: :bad_request
    end

    rows = build_property_rows(cps_in_text, config[:columns])

    if params[:download].to_s == "csv"
      return send_data(
        generate_property_csv(rows, config[:columns]),
        type: "text/csv; charset=utf-8",
        filename: "character_data_extract.csv",
        disposition: "attachment"
      )
    end

    render partial: "tools/property_extract_output",
           locals: {
             extractor_label: config[:label],
             field_columns: config[:columns],
             rows: rows,
             message: nil
           }
  end

  private

  def handle_cangjie_only(raw)
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

    cps_in_text =
      if raw.match?(/\AU\+[0-9A-Fa-f]+\z/) || raw.match?(/\A[0-9A-Fa-f]+\z/)
        cp = parse_codepoint(raw)
        return render(partial: "tools/cangjie_output",
                      locals: { char: nil, codepoint: nil, lines: [], message: "Could not parse a character/codepoint." },
                      status: :bad_request) if cp.nil?
        [cp]
      else
        extract_han_codepoints(raw)
      end

    if cps_in_text.length == 1
      cp = cps_in_text.first
      cc = CharacterCodepoint.find_by(codepoint: cp)
      return render partial: "tools/cangjie_output",
                    locals: { char: [cp].pack("U"), codepoint: cp, lines: [], message: "Not found in DB." },
                    status: :not_found if cc.nil?

      props = CharacterProperty.where(character_codepoint_id: cc.id, field: "kCangjie").order(:source, :value)
      lines = if props.empty?
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

    rows = build_cangjie_rows(cps_in_text)
    show_hkcards = params[:hkcards].to_s == "1"

    if show_hkcards
      render partial: "tools/cangjie_table_output", locals: { rows: rows, message: nil }
    else
      lines = rows.map do |r|
        if r[:codes].empty?
          "* #{r[:char]}: (no Cangjie code)"
        else
          combos = r[:codes].map { |c| "#{c[:han]} (#{c[:latin]})" }.join(" / ")
          "* #{r[:char]}: #{combos}"
        end
      end
      render partial: "tools/cangjie_list_output", locals: { lines: lines, message: nil }
    end
  end

  def handle_anki_enrich
    input_text = params[:input].to_s
    default_locals = {
      message: nil,
      note_count: 0,
      updated_count: 0,
      sample_html: nil,
      output_text: "",
      target_field_number: nil,
      source_field_number: nil,
      append_mode: "append",
      target_nonempty_count: 0,
      changed_with_existing_target_count: 0,
      skipped_count: 0,
      preview_limit: 10,
      preview_start: 1,
      preview_mode: "changed_only",
      preview_rows: [],
      detected_field_count: nil,
      metadata_max_field: nil
    }

    return render partial: "tools/anki_enrich_output",
                  locals: default_locals.merge(message: "No Anki TXT pasted."),
                  status: :bad_request if input_text.strip.empty?

    source_index = params[:source_field].to_i - 1
    target_index = params[:target_field].to_i - 1
    enrich_fields = Array(params[:enrich_fields]).map(&:to_s).select { |f| ENRICHABLE_FIELD_OPTIONS.key?(f) }
    append_mode = params[:append_mode].to_s == "replace" ? "replace" : "append"

    if source_index.negative? || target_index.negative?
      return render partial: "tools/anki_enrich_output",
                    locals: default_locals.merge(message: "Field numbers must be 1 or greater."),
                    status: :bad_request
    end

    enrich_fields = ["kangxi_gloss"] if enrich_fields.empty?

    preview_limit = params[:preview_limit].to_i
    preview_limit = 10 if preview_limit <= 0
    preview_limit = 250 if preview_limit > 250

    preview_start = params[:preview_start].to_i
    preview_start = 1 if preview_start <= 0

    preview_mode = params[:preview_mode].to_s == "full_rows" ? "full_rows" : "changed_only"

    lines = input_text.gsub("
", "
").gsub("", "
").split("
", -1)
    detected_field_count = 0
    metadata_max_field = 0
    metadata_pattern = /#(?:guid|notetype|deck|tags)\s+column:(\d+)/i

    lines.each do |line|
      if line.start_with?("#")
        match = line.match(metadata_pattern)
        metadata_max_field = [metadata_max_field, match[1].to_i].max if match
        next
      end
      next if line.empty?
      detected_field_count = [detected_field_count, line.split("	", -1).length].max
    end

    detected_field_count = [detected_field_count, metadata_max_field].max

    output_lines = []
    preview_candidates = []
    note_count = 0
    updated_count = 0
    target_nonempty_count = 0
    changed_with_existing_target_count = 0
    skipped_count = 0
    sample_html = nil

    lines.each do |line|
      if line.start_with?("#") || line.empty?
        output_lines << line
        next
      end

      cols = line.split("	", -1)
      needed_size = [source_index, target_index, detected_field_count - 1].max + 1
      cols.fill("", cols.length...needed_size) if cols.length < needed_size

      source_text = cols[source_index].to_s
      target_before = cols[target_index].to_s
      html = build_anki_enrichment_html(source_text, enrich_fields)
      sample_html ||= html if html.present?

      target_nonempty_count += 1 if target_before.present?

      if html.blank?
        target_after = target_before
        status = "skipped"
        skipped_count += 1
      elsif append_mode == "replace"
        target_after = html
        if target_before.present?
          changed_with_existing_target_count += 1
          status = "replace (target had content)"
        else
          status = "replace"
        end
        updated_count += 1
      elsif target_before.present?
        target_after = "#{target_before}#{html}"
        changed_with_existing_target_count += 1
        status = "append (target had content)"
        updated_count += 1
      else
        target_after = html
        status = "append"
        updated_count += 1
      end

      cols[target_index] = target_after
      note_count += 1
      output_lines << cols.join("	")
      preview_candidates << {
        row_number: note_count,
        guid: cols[0].to_s,
        source_before: source_text,
        target_before: target_before,
        target_after: target_after,
        status: status
      }
    end

    preview_source = if preview_mode == "full_rows"
                       preview_candidates
                     else
                       preview_candidates.reject { |row| row[:status] == "skipped" }
                     end
    preview_rows = preview_source.drop(preview_start - 1).first(preview_limit)

    render partial: "tools/anki_enrich_output",
           locals: default_locals.merge(
             message: nil,
             note_count: note_count,
             updated_count: updated_count,
             sample_html: sample_html,
             output_text: output_lines.join("
"),
             target_field_number: target_index + 1,
             source_field_number: source_index + 1,
             append_mode: append_mode,
             target_nonempty_count: target_nonempty_count,
             changed_with_existing_target_count: changed_with_existing_target_count,
             skipped_count: skipped_count,
             preview_limit: preview_limit,
             preview_start: preview_start,
             preview_mode: preview_mode,
             preview_rows: preview_rows,
             detected_field_count: detected_field_count,
             metadata_max_field: metadata_max_field
           )
  end

  def build_anki_enrichment_html(source_text, enrich_fields)
    cps = extract_han_codepoints(source_text)
    return "" if cps.empty?

    unique_cps = unique_codepoints(cps)
    rows = build_property_rows(unique_cps, enrich_fields.map { |field| { field: field, label: ENRICHABLE_FIELD_OPTIONS[field] } })
    return "" if rows.empty?

    entries = rows.map do |row|
      items = enrich_fields.filter_map do |field|
        values = (row[:values_by_field][field] || []).map { |entry| compact_field_text(entry[:value]) }.reject(&:blank?).uniq
        next if values.empty?
        label = ENRICHABLE_FIELD_OPTIONS[field]
        "<li><strong>#{ERB::Util.html_escape(label)}:</strong> #{ERB::Util.html_escape(values.join(' / '))}</li>"
      end
      next if items.empty?

      "<div class=\"char-entry\" data-char=\"#{ERB::Util.html_escape(row[:char])}\"><div class=\"char-entry-head\"><strong>#{ERB::Util.html_escape(row[:char])}</strong> (U+#{row[:codepoint].to_i.to_s(16).upcase})</div><ul>#{items.join}</ul></div>"
    end.compact

    return "" if entries.empty?

    "<div class=\"character-enrichment\">#{entries.join}</div>".gsub(/[\n\t]/, "").gsub(/>\s+</, "><")
  end

  def build_cangjie_rows(codepoints)
    unique_cps = unique_codepoints(codepoints)
    ccs = CharacterCodepoint.where(codepoint: unique_cps).to_a
    cc_by_cp = ccs.index_by(&:codepoint)
    props = CharacterProperty.where(character_codepoint_id: ccs.map(&:id), field: "kCangjie").order(:source, :value).to_a
    props_by_ccid = props.group_by(&:character_codepoint_id)

    unique_cps.map do |cp|
      cc = cc_by_cp[cp]
      pps = cc ? (props_by_ccid[cc.id] || []) : []
      codes = pps.map do |p|
        latin = CangjieKeymap.normalise_cangjie(p.value.to_s)
        han   = CangjieKeymap.latin_to_han(latin)
        { latin: latin, han: han, source: p.source.to_s }
      end.uniq { |c| c[:latin] }

      { char: [cp].pack("U"), codepoint: cp, found_in_db: cc.present?, codes: codes }
    end
  end

  def build_property_rows(codepoints, field_columns)
    unique_cps = unique_codepoints(codepoints)
    ccs = CharacterCodepoint.where(codepoint: unique_cps).to_a
    cc_by_cp = ccs.index_by(&:codepoint)
    props = CharacterProperty.where(character_codepoint_id: ccs.map(&:id), field: field_columns.map { |c| c[:field] }).order(:field, :source, :value).to_a
    props_by_ccid = props.group_by(&:character_codepoint_id)

    unique_cps.map do |cp|
      cc = cc_by_cp[cp]
      grouped = Hash.new { |h, k| h[k] = [] }

      if cc
        (props_by_ccid[cc.id] || []).each do |prop|
          grouped[prop.field] << { value: prop.value.to_s, source: prop.source.to_s }
        end
      end

      {
        char: [cp].pack("U"),
        codepoint: cp,
        values_by_field: grouped
      }
    end
  end

  def generate_property_csv(rows, field_columns)
    CSV.generate do |csv|
      csv << ["Character", "Codepoint", *field_columns.map { |c| c[:label] }, *field_columns.map { |c| "#{c[:label]} source" }]
      rows.each do |row|
        values = field_columns.map do |column|
          (row[:values_by_field][column[:field]] || []).map { |entry| compact_field_text(entry[:value]) }.reject(&:blank?).uniq.join(" / ")
        end
        sources = field_columns.map do |column|
          (row[:values_by_field][column[:field]] || []).map { |entry| compact_field_text(entry[:source]) }.reject(&:blank?).uniq.join(" / ")
        end
        csv << [row[:char], "U+#{row[:codepoint].to_i.to_s(16).upcase}", *values, *sources]
      end
    end
  end

  def extract_han_codepoints(text)
    cps = []
    text.to_s.each_codepoint do |cp|
      next if [9, 10, 13, 32].include?(cp)
      next unless UnicodeRanges.han?(cp)
      cps << cp
    end
    cps
  end

  def unique_codepoints(codepoints)
    seen = {}
    codepoints.each_with_object([]) do |cp, ary|
      next if seen[cp]
      seen[cp] = true
      ary << cp
    end
  end

  def compact_field_text(text)
    text.to_s.gsub(/[\n\r\t]+/, " ").gsub(/\s+/, " ").strip
  end

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

  def parse_western_date(input:, date_iso:)
    s = (date_iso.presence || input).to_s.strip
    return [nil, nil] if s.empty?

    down = s.downcase
    return [Date.current, nil] if %w[today now].include?(down)
    return [Date.yesterday, nil] if down == "yesterday"
    return [Date.tomorrow, nil] if down == "tomorrow"

    if (m = s.match(/\A(\d{4})[\/\-.](\d{1,2})[\/\-.](\d{1,2})\z/))
      y, mo, d = m.captures.map(&:to_i)
      return [Date.new(y, mo, d), nil]
    end

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

    return [Date.parse(s), nil] if s.match?(/[A-Za-z]/)

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
