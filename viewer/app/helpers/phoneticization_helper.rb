module PhoneticizationHelper
  def current_mandarin_scheme
    raw = session[:mandarin_scheme]
    raw = :pinyin_diacritics if raw.blank?
    sym = raw.to_s.strip.downcase.tr(" ", "_").to_sym
    allowed = [:original] + Phoneticization::Converters::MANDARIN_SCHEMES.keys
    allowed.include?(sym) ? sym : :pinyin_diacritics
  end

  def current_cantonese_scheme
    raw = session[:cantonese_scheme]
    raw = :jyutping if raw.blank?
    sym = raw.to_s.strip.downcase.tr(" ", "_").to_sym
    allowed = [:original] + Phoneticization::Converters::CANTONESE_SCHEMES.keys
    allowed.include?(sym) ? sym : :jyutping
  end

  # Old National Pronunciation (老國音)
  # -------------------------------
  # Stored in the database (table: laoguoyin_readings), *not* in Unihan.
  #
  # We still expose it in the UI under "Phoneticization conventions" so it
  # behaves like Mandarin/Cantonese: the user selects a display convention.
  #
  # Conventions:
  #   :original  -> show all components (Latin + Zhuyin + IPA) when present
  #   :latin     -> show only Latin romanisation
  #   :zhuyin    -> show only Zhuyin
  #   :ipa       -> show only IPA
  def current_laoguoyin_scheme
    raw = session[:laoguoyin_scheme]
    # Default to Latin so ruby annotations are readable immediately without
    # requiring the user to configure anything.
    raw = :latin if raw.blank?
    sym = raw.to_s.strip.downcase.tr(" ", "_").to_sym
    allowed = [:original, :latin, :zhuyin, :ipa]
    allowed.include?(sym) ? sym : :latin
  end

  # Backward-compatible name used in some helpers
  def romanise_unihan_value(field, value)
    phoneticize_unihan_value(field, value)
  end

  def phoneticize_unihan_value(field, value)
    return value if value.nil?
    raw = value.to_s

    # Allow the user to keep Unihan output exactly as-is.
    if field == "kMandarin" && current_mandarin_scheme == :original
      return raw
    end
    if field == "kCantonese" && current_cantonese_scheme == :original
      return raw
    end

    # Old National Pronunciation values are injected into @properties as field
    # "laoguoyin". They are pre-composed as:
    #   "<latin> <zhuyin> /<ipa>/"
    #
    # We do NOT attempt to convert between schemes. We simply select which
    # component to display.
    if field == "laoguoyin"
      return format_laoguoyin_value(raw, scheme: current_laoguoyin_scheme)
    end

    tokens = raw.strip.split(/\s+/).reject(&:blank?)

    converted =
      case field
      when "kMandarin"
        tokens.map do |tok|
          from = detect_pinyin_input_scheme(tok)
          Phoneticization::Converters.mandarin(tok, from: from, to: current_mandarin_scheme) || tok
        end
      when "kCantonese"
        tokens.map do |tok|
          Phoneticization::Converters.cantonese(tok, from: :jyutping, to: current_cantonese_scheme) || tok
        end
      when "kKorean"
        # Unihan uses uppercase Yale-ish romanisation; show it in a more readable form.
        tokens.map { |tok| tok.downcase }
      when "kJapaneseKun"
        # Unihan often stores romanised kun readings in ALLCAPS.
        tokens.map { |tok| tok.downcase }
      when "kHangul"
        # Unihan sometimes appends romanisation after a colon, e.g. "트:OE".
        tokens.map do |tok|
          if tok.include?(":")
            left, _right = tok.split(":", 2)
            left.match?(/\p{Hangul}/) ? left : tok
          else
            tok
          end
        end
      else
        tokens
      end

    # If conversion collapses multiple readings into duplicates, de-dupe while preserving order.
    seen = {}
    deduped = converted.each_with_object([]) do |tok, out|
      next if tok.blank?
      next if seen[tok]
      seen[tok] = true
      out << tok
    end

    (deduped.presence || tokens.presence || [raw]).join(" ")
  rescue StandardError
    raw
  end

  # Format a single laoguoyin property value according to scheme.
  # Input shape (best-effort): "latin zhuyin /ipa/".
  def format_laoguoyin_value(raw, scheme:)
    parts = split_laoguoyin_parts(raw)

    case scheme.to_sym
    when :latin
      parts[:latin].presence || raw
    when :zhuyin
      parts[:zhuyin].presence || raw
    when :ipa
      ipa = parts[:ipa]
      return raw if ipa.blank?
      ipa.start_with?("/") ? ipa : "/#{ipa}/"
    else
      # :original (or unknown): show all components that exist, in a stable order.
      out = []
      out << parts[:latin] if parts[:latin].present?
      out << parts[:zhuyin] if parts[:zhuyin].present?
      if parts[:ipa].present?
        ipa = parts[:ipa]
        out << (ipa.start_with?("/") ? ipa : "/#{ipa}/")
      end
      # Avoid spaces so ruby <rt> does not wrap/staircase. The full-width
      # vertical bar is also readable in dropdowns.
      out.presence ? out.join("｜") : raw
    end
  end

  # Extract Latin / Zhuyin / IPA from a laoguoyin property value.
  # This is intentionally permissive; the source text is not guaranteed to be
  # perfectly regular.
  def split_laoguoyin_parts(raw)
    s = raw.to_s

    # 1) IPA: prefer /.../ chunks.
    ipa = s[/\/[^\/]+\//]
    s_wo_ipa = s.dup
    s_wo_ipa.sub!(ipa, " ") if ipa
    ipa = ipa.to_s.strip
    ipa = ipa[1..-2] if ipa.start_with?("/") && ipa.end_with?("/") && ipa.length >= 2

    # 2) Zhuyin: Bopomofo block(s). Keep the longest match.
    #    U+3105..U+312F (Bopomofo), U+31A0..U+31BF (Bopomofo Extended)
    zhuyin_matches = s_wo_ipa.scan(/[\u3105-\u312F\u31A0-\u31BF]+[1-5ˊˇˋ˙]?/)
    zhuyin = zhuyin_matches.max_by { |m| m.length }.to_s.strip
    s_wo_zhuyin = s_wo_ipa.dup
    s_wo_zhuyin.sub!(zhuyin, " ") if zhuyin.present?

    # 3) Latin: remaining text, normalised.
    latin = s_wo_zhuyin.gsub(/\s+/, " ").strip

    { latin: latin.presence, zhuyin: zhuyin.presence, ipa: ipa.presence }
  end

  private


  def detect_pinyin_input_scheme(s)
    # Digits => tone numbers. Any diacritic vowel => tone marks.
    return :pinyin_numbers if s.match?(/[1-5]/)
    return :pinyin_diacritics if s.match?(/[āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜ]/)
    :pinyin_diacritics
  end
end
