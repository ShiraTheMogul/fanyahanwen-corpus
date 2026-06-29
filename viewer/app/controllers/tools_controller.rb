# frozen_string_literal: true

require "csv"

class ToolsController < ApplicationController
  EXTRACTOR_OPTIONS = [
    ["tools.character_extractor.options.cangjie", "cangjie"],
    ["tools.character_extractor.options.unicode_definition", "unicode_definition"],
    ["tools.character_extractor.options.kangxi_entry", "kangxi_entry"],
    ["tools.character_extractor.options.shuowen_entry", "shuowen_entry"],
    ["tools.character_extractor.options.guangyun_definition", "guangyun_definition"],
    ["tools.character_extractor.options.guangyun_fanqie", "guangyun_fanqie"],
    ["tools.character_extractor.options.guangyun_rhyme", "guangyun_rhyme"],
    ["tools.character_extractor.options.guangyun_tone", "guangyun_tone"],
    ["tools.character_extractor.options.mandarin", "mandarin"],
    ["tools.character_extractor.options.cantonese", "cantonese"],
    ["tools.character_extractor.options.japanese_on", "japanese_on"],
    ["tools.character_extractor.options.korean", "korean"],
    ["tools.character_extractor.options.vietnamese", "vietnamese"],
    ["tools.character_extractor.options.common_readings", "common_readings"]
  ].freeze

  EXTRACT_FIELD_CONFIGS = {
    "unicode_definition" => {
      label_key: "tools.character_extractor.options.unicode_definition",
      columns: [{ field: "kDefinition", label_key: "tools.character_extractor.columns.unicode_definition" }]
    },
    "kangxi_entry" => {
      label_key: "tools.character_extractor.options.kangxi_entry",
      columns: [{ field: "kangxi_gloss", label_key: "tools.character_extractor.columns.kangxi_definition" }]
    },
    "shuowen_entry" => {
      label_key: "tools.character_extractor.options.shuowen_entry",
      columns: [{ field: "shuowen_entry", label_key: "tools.character_extractor.columns.shuowen_entry" }]
    },
    "guangyun_definition" => {
      label_key: "tools.character_extractor.options.guangyun_definition",
      columns: [{ field: "guangyun_definition", label_key: "tools.character_extractor.columns.guangyun_definition" }]
    },
    "guangyun_fanqie" => {
      label_key: "tools.character_extractor.options.guangyun_fanqie",
      columns: [{ field: "guangyun_fanqie", label_key: "tools.character_extractor.columns.guangyun_fanqie" }]
    },
    "guangyun_rhyme" => {
      label_key: "tools.character_extractor.options.guangyun_rhyme",
      columns: [{ field: "guangyun_rhyme", label_key: "tools.character_extractor.columns.guangyun_rhyme" }]
    },
    "guangyun_tone" => {
      label_key: "tools.character_extractor.options.guangyun_tone",
      columns: [{ field: "guangyun_tone", label_key: "tools.character_extractor.columns.guangyun_tone" }]
    },
    "mandarin" => {
      label_key: "tools.character_extractor.options.mandarin",
      columns: [{ field: "kMandarin", label_key: "tools.character_extractor.columns.mandarin" }]
    },
    "cantonese" => {
      label_key: "tools.character_extractor.options.cantonese",
      columns: [{ field: "kCantonese", label_key: "tools.character_extractor.columns.cantonese" }]
    },
    "japanese_on" => {
      label_key: "tools.character_extractor.options.japanese_on",
      columns: [{ field: "kJapaneseOn", label_key: "tools.character_extractor.columns.japanese_on" }]
    },
    "korean" => {
      label_key: "tools.character_extractor.options.korean",
      columns: [
        { field: "kKorean", label_key: "tools.character_extractor.columns.korean_yale" },
        { field: "kHangul", label_key: "tools.character_extractor.columns.korean_hangul" }
      ]
    },
    "vietnamese" => {
      label_key: "tools.character_extractor.options.vietnamese",
      columns: [{ field: "kVietnamese", label_key: "tools.character_extractor.columns.vietnamese" }]
    },
    "common_readings" => {
      label_key: "tools.character_extractor.options.common_readings",
      columns: [
        { field: "kMandarin", label_key: "tools.character_extractor.columns.mandarin" },
        { field: "kCantonese", label_key: "tools.character_extractor.columns.cantonese" },
        { field: "kJapaneseOn", label_key: "tools.character_extractor.columns.japanese_on" },
        { field: "kKorean", label_key: "tools.character_extractor.columns.korean_yale" },
        { field: "kHangul", label_key: "tools.character_extractor.columns.korean_hangul" },
        { field: "kVietnamese", label_key: "tools.character_extractor.columns.vietnamese" }
      ]
    }
  }.freeze

  ENRICHABLE_FIELD_OPTIONS = {
    "kangxi_gloss" => "tools.anki.fields.kangxi_gloss",
    "kDefinition" => "tools.anki.fields.unicode_definition",
    "shuowen_entry" => "tools.anki.fields.shuowen_entry",
    "guangyun_definition" => "tools.anki.fields.guangyun_definition",
    "guangyun_fanqie" => "tools.anki.fields.guangyun_fanqie",
    "guangyun_rhyme" => "tools.anki.fields.guangyun_rhyme",
    "guangyun_tone" => "tools.anki.fields.guangyun_tone",
    "kMandarin" => "tools.anki.fields.mandarin",
    "kCantonese" => "tools.anki.fields.cantonese",
    "kJapaneseOn" => "tools.anki.fields.japanese_on",
    "kKorean" => "tools.anki.fields.korean_yale",
    "kHangul" => "tools.anki.fields.korean_hangul",
    "kVietnamese" => "tools.anki.fields.vietnamese"
  }.freeze

  def index
    @extractor_options = localized_extractor_options
    @enrichable_field_options = localized_enrichable_field_options
  end

  # --- Lunar calendar converter ------------------------------------------
  def lunar
    date, warning_key = parse_western_date(
      input: params[:input].to_s,
      date_iso: params[:date_iso].to_s
    )

    if date.nil?
      return render partial: "tools/tool_output",
                    locals: { frame_id: "lunar_out", output: I18n.t("tools.lunar.parse_failed") },
                    status: :bad_request
    end

    lunar = LunarCalendar.at_lunar(date.year, date.month, date.day)

    out = []
    out << "#{I18n.t('tools.lunar.solar')}#{I18n.t('tools.common.label_separator')} #{date.iso8601}"
    out << "#{I18n.t('tools.lunar.lunar')}#{I18n.t('tools.common.label_separator')} #{format_lunar(lunar)}"
    out << "#{I18n.t('tools.lunar.note')}#{I18n.t('tools.common.label_separator')} #{I18n.t(warning_key)}" if warning_key.present?

    render partial: "tools/tool_output",
           locals: { frame_id: "lunar_out", output: out.join("\n") }
  rescue StandardError => e
    render partial: "tools/tool_output",
           locals: {
             frame_id: "lunar_out",
             output: I18n.t("tools.common.error", message: "#{e.class}: #{e.message}")
           },
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
                    locals: { frame_id: "mandarin_out", output: I18n.t("tools.common.allowed", schemes: allowed.sort.join(", ")) },
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
                    locals: { frame_id: "cantonese_out", output: I18n.t("tools.common.allowed", schemes: allowed.sort.join(", ")) },
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
                  locals: { char: nil, codepoint: nil, lines: [], message: I18n.t("tools.character_extractor.messages.no_input") },
                  status: :bad_request if raw.empty?

    extractor_key = params[:extract].presence || "cangjie"
    return handle_cangjie_only(raw) if extractor_key == "cangjie"

    config = localized_extract_config(extractor_key)
    unless config
      return render partial: "tools/tool_output",
                    locals: { frame_id: "cangjie_out", output: I18n.t("tools.character_extractor.messages.unknown_extractor") },
                    status: :bad_request
    end

    cps_in_text = extract_han_codepoints(raw)
    if cps_in_text.empty?
      return render partial: "tools/tool_output",
                    locals: { frame_id: "cangjie_out", output: I18n.t("tools.character_extractor.messages.no_han") },
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
                      char: nil,
                      codepoint: nil,
                      lines: [
                        "#{I18n.t('tools.character_extractor.messages.latin')}#{I18n.t('tools.common.label_separator')} #{latin}",
                        "#{I18n.t('tools.character_extractor.messages.han')}#{I18n.t('tools.common.label_separator')} #{han}"
                      ],
                      message: I18n.t("tools.character_extractor.messages.cangjie_letters")
                    }
    end

    cps_in_text =
      if raw.match?(/\AU\+[0-9A-Fa-f]+\z/) || raw.match?(/\A[0-9A-Fa-f]+\z/)
        cp = parse_codepoint(raw)
        return render(partial: "tools/cangjie_output",
                      locals: {
                        char: nil,
                        codepoint: nil,
                        lines: [],
                        message: I18n.t("tools.character_extractor.messages.parse_failed")
                      },
                      status: :bad_request) if cp.nil?
        [cp]
      else
        extract_han_codepoints(raw)
      end

    if cps_in_text.length == 1
      cp = cps_in_text.first
      cc = CharacterCodepoint.find_by(codepoint: cp)
      return render partial: "tools/cangjie_output",
                    locals: {
                      char: [cp].pack("U"),
                      codepoint: cp,
                      lines: [],
                      message: I18n.t("tools.character_extractor.messages.not_found")
                    },
                    status: :not_found if cc.nil?

      props = CharacterProperty.where(character_codepoint_id: cc.id, field: "kCangjie").order(:source, :value)
      lines = if props.empty?
                [I18n.t("tools.character_extractor.messages.no_cangjie_property")]
              else
                props.map do |prop|
                  latin = CangjieKeymap.normalise_cangjie(prop.value.to_s)
                  han   = CangjieKeymap.latin_to_han(latin)
                  "#{latin} (#{han}) — #{prop.source}"
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
      lines = rows.map do |row|
        if row[:codes].empty?
          "* #{row[:char]}: (#{I18n.t('tools.character_extractor.messages.no_cangjie_code')})"
        else
          combinations = row[:codes].map { |code| "#{code[:han]} (#{code[:latin]})" }.join(" / ")
          "* #{row[:char]}: #{combinations}"
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
                  locals: default_locals.merge(message: I18n.t("tools.anki.errors.no_text")),
                  status: :bad_request if input_text.strip.empty?

    source_index = params[:source_field].to_i - 1
    target_index = params[:target_field].to_i - 1
    enrich_fields = Array(params[:enrich_fields]).map(&:to_s).select { |field| ENRICHABLE_FIELD_OPTIONS.key?(field) }
    append_mode = params[:append_mode].to_s == "replace" ? "replace" : "append"

    if source_index.negative? || target_index.negative?
      return render partial: "tools/anki_enrich_output",
                    locals: default_locals.merge(message: I18n.t("tools.anki.errors.field_minimum")),
                    status: :bad_request
    end

    enrich_fields = ["kangxi_gloss"] if enrich_fields.empty?

    preview_limit = params[:preview_limit].to_i
    preview_limit = 10 if preview_limit <= 0
    preview_limit = 250 if preview_limit > 250

    preview_start = params[:preview_start].to_i
    preview_start = 1 if preview_start <= 0

    preview_mode = params[:preview_mode].to_s == "full_rows" ? "full_rows" : "changed_only"

    lines = input_text.gsub("\r\n", "\n").gsub("\r", "\n").split("\n", -1)
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

      detected_field_count = [detected_field_count, line.split("\t", -1).length].max
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

      columns = line.split("\t", -1)
      needed_size = [source_index, target_index, detected_field_count - 1].max + 1
      columns.fill("", columns.length...needed_size) if columns.length < needed_size

      source_text = columns[source_index].to_s
      target_before = columns[target_index].to_s
      html = build_anki_enrichment_html(source_text, enrich_fields)
      sample_html ||= html if html.present?

      target_nonempty_count += 1 if target_before.present?

      if html.blank?
        target_after = target_before
        status = :skipped
        skipped_count += 1
      elsif append_mode == "replace"
        target_after = html
        if target_before.present?
          changed_with_existing_target_count += 1
          status = :replace_existing
        else
          status = :replace
        end
        updated_count += 1
      elsif target_before.present?
        target_after = "#{target_before}#{html}"
        changed_with_existing_target_count += 1
        status = :append_existing
        updated_count += 1
      else
        target_after = html
        status = :append
        updated_count += 1
      end

      columns[target_index] = target_after
      note_count += 1
      output_lines << columns.join("\t")
      preview_candidates << {
        row_number: note_count,
        guid: columns[0].to_s,
        source_before: source_text,
        target_before: target_before,
        target_after: target_after,
        status: status
      }
    end

    preview_source = if preview_mode == "full_rows"
                       preview_candidates
                     else
                       preview_candidates.reject { |row| row[:status] == :skipped }
                     end
    preview_rows = preview_source.drop(preview_start - 1).first(preview_limit)

    render partial: "tools/anki_enrich_output",
           locals: default_locals.merge(
             message: nil,
             note_count: note_count,
             updated_count: updated_count,
             sample_html: sample_html,
             output_text: output_lines.join("\n"),
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
    rows = build_property_rows(unique_cps, enrich_fields.map { |field| { field: field, label: enrichable_field_label(field) } })
    return "" if rows.empty?

    entries = rows.map do |row|
      items = enrich_fields.filter_map do |field|
        values = (row[:values_by_field][field] || []).map { |entry| compact_field_text(entry[:value]) }.reject(&:blank?).uniq
        next if values.empty?
        label = enrichable_field_label(field)
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
      csv << [
        I18n.t("tools.common.character"),
        I18n.t("tools.common.codepoint"),
        *field_columns.map { |column| column[:label] },
        *field_columns.map { |column| I18n.t("tools.character_extractor.csv_source", label: column[:label]) }
      ]
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

  def localized_extractor_options
    EXTRACTOR_OPTIONS.map { |key, value| [I18n.t(key), value] }
  end

  def localized_enrichable_field_options
    ENRICHABLE_FIELD_OPTIONS.transform_values { |key| I18n.t(key) }
  end

  def localized_extract_config(extractor_key)
    config = EXTRACT_FIELD_CONFIGS[extractor_key]
    return nil unless config

    {
      label: I18n.t(config[:label_key]),
      columns: config[:columns].map do |column|
        { field: column[:field], label: I18n.t(column[:label_key]) }
      end
    }
  end

  def enrichable_field_label(field)
    key = ENRICHABLE_FIELD_OPTIONS.fetch(field)
    I18n.t(key)
  end

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
        return [Date.new(y, a, b), "tools.lunar.warnings.month_first"]
      else
        return [Date.new(y, b, a), "tools.lunar.warnings.ambiguous"]
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
