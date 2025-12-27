# frozen_string_literal: true

module CharactersHelper
  # ------------------------------------------------------------------
  # Ruby display (furigana-style readings, but for more languages)
  # ------------------------------------------------------------------
  # We store these preferences in the session:
  #   :ruby_enabled     -> boolean
  #   :ruby_source      -> :mandarin | :cantonese | :japanese | :korean | :vietnamese
  #   :ruby_orientation -> :horizontal | :verticalside

  UNIHAN_READING_SOURCES = ["Unihan_Readings", "Unihan"].freeze

  def ruby_enabled?
    v = session[:ruby_enabled]
    v == true || v.to_s == "true" || v.to_s == "1"
  end

  def current_ruby_source
    raw = session[:ruby_source]
    raw = :mandarin if raw.blank?
    raw.to_sym
  end

  
# --- Ruby reading sub-options ---------------------------------------
# Japanese readings in Unihan are typically *Hepburn romanization* (not kana),
# so we optionally generate kana (best-effort).
def current_japanese_ruby_style
  (session[:japanese_ruby_style] || "romaji").to_s
end

# If a Japanese reading has "a/b" alternatives, pick side 0 or 1.
def current_japanese_alt_index
  (session[:japanese_alt_index] || 0).to_i
end

# Korean: kKorean is Yale romanization. Hangul is usually in kHangul.
def current_korean_ruby_style
  (session[:korean_ruby_style] || "Phoneticization").to_s
end

def current_ruby_orientation
    raw = session[:ruby_orientation]
    raw = :horizontal if raw.blank?

    sym = raw.to_sym
    # UI stores :verticalside as a distinct option, but CSS logic wants :vertical.
    sym = :vertical if sym == :verticalside
    sym
  end

  # Which side to place vertical ruby text on.
  # (Ruby vertical is written top-to-bottom; "side" controls left vs right of glyph.)
  def current_ruby_side
    raw = session[:ruby_side]
    raw = :right if raw.blank?
    raw.to_sym
  end


  # Render a single displayed character (glyph). If ruby is enabled and we can
  # find a reading, we wrap it in HTML <ruby> ... <rt>.
  #
  # IMPORTANT:
  # - `glyph` should be a string (usually a single-character string).
  # - We keep it as a string so the caller can pass `view_text(@character.chr)`
  #   (i.e., after Traditional/Simplified display conversion).
  def character_glyph_with_ruby(glyph)
    glyph = glyph.to_s
    return glyph if glyph.blank?
    return glyph unless ruby_enabled?

    reading = ruby_reading_for(current_ruby_source)
    return glyph if reading.blank?

    ruby_class_parts = ["ruby-annot", "ruby-#{current_ruby_orientation}"]
    ruby_class_parts << "ruby-side-#{current_ruby_side}" if current_ruby_orientation == :vertical
    ruby_class = ruby_class_parts.join(" ")

    content_tag(:ruby, class: ruby_class) do
      concat(glyph)
      concat(content_tag(:rt, reading))
    end
  end

  # Pull a reading string for the requested language/source.
  #
  # We prefer the current character's own Unihan fields when present.
  # If missing, we fall back to the base character, then to other variants.
    def ruby_reading_for(source)
    src = (source.presence || :mandarin).to_sym

    # 1) Pull the list of available readings for this character+source.
    tokens = ruby_reading_tokens_for(src)

    # 2) Pick which token the user wants (stored in session[:ruby_token]).
    tok = pick_ruby_token_from_session(tokens)

    return nil if tok.blank?

    # 3) Apply per-source formatting (e.g., kana conversion) but do NOT
    #    try to "pretty-print" a whole list here. Ruby text should be one
    #    short annotation.
    case src
    when :laoguoyin
      # Old National Pronunciation (老國音): already formatted according to the
      # user-selected "Phoneticization conventions" setting.
      tok
    when :mandarin
      romanise_unihan_value("kMandarin", tok)
    when :cantonese
      romanise_unihan_value("kCantonese", tok)

    when :japanese
      # kJapanese is usually kana already (space-separated). We show the chosen token.
      tok
    when :japanese_kana
      # Try to ensure kana. If the token is already kana, keep it.
      tok.match?(/[\p{Hiragana}\p{Katakana}]/) ? tok : hepburn_to_kana(tok)
    when :japanese_on
      tok
    when :japanese_kun
      tok

    when :korean_yale
      tok
    when :korean_hangul
      # Some sources include extra info after a colon, e.g. "가: ka".
      tok.to_s.sub(/[：:].*$/, "").strip
    when :vietnamese
      tok
    else
      tok
    end
  end


  # Return an array of possible ruby readings (tokens) for the given source,
  # taken from the Unihan reading fields for the *current* character family.
  #
  # Why we return tokens:
  # - Unihan fields often contain multiple readings in ONE value (space-separated).
  # - Ruby text should be ONE short annotation for a glyph.
  # - The sidebar can show a "Reading" dropdown if there are multiple tokens.
  def ruby_reading_tokens_for(source_sym)
    # Old National Pronunciation does not live in Unihan. It is injected into
    # @properties as field "laoguoyin" by CharactersController.
    if source_sym.to_sym == :laoguoyin
      return laoguoyin_ruby_tokens
    end

    field_name =
      case source_sym
      when :mandarin then "kMandarin"
      when :fanqie then "kFanqie"
      when :tang then "kTang"
      when :cantonese then "kCantonese"
      when :japanese then "kJapanese"
      when :japanese_on then "kJapaneseOn"
      when :japanese_kun then "kJapaneseKun"
      when :japanese_kana then "kJapanese"
      when :korean_yale then "kKorean"
      when :korean_hangul then "kHangul"
      when :vietnamese then "kVietnamese"
	  when :zhuang then "kZhuang"
	  when :fanqie then "kFanqie"
	  when :tang then "kTang"
      else nil
      end

    return [] if field_name.nil?

    raw = preferred_unihan_reading(field_name: field_name)
    tokens = split_unihan_tokens(raw)

    # Expand tokens that look like "A/B" into ["A", "B"] so the user can select
    # the actual reading directly (no "left-of" explanations).
    expanded = []
    tokens.each do |t|
      parts = t.split("/").map { |x| x.strip }.reject(&:blank?)
      if parts.length >= 2
        expanded.concat(parts)
      else
        expanded << t
      end
    end

    # De-dupe while preserving order
    seen = {}
    expanded.each_with_object([]) do |t, out|
      next if t.blank?
      next if seen[t]
      seen[t] = true
      out << t
    end
  end

  # Return possible Old National Pronunciation ruby tokens for the current
  # character family.
  #
  # We prefer current -> base -> variants, matching how other "best value"
  # helpers behave.
  def laoguoyin_ruby_tokens
    props = Array(@properties)
    return [] if props.empty?

    preferred_ids = [@character&.id, @base_character&.id, *@variant_characters&.map(&:id)].compact


    scheme = respond_to?(:current_laoguoyin_scheme) ? current_laoguoyin_scheme : :latin

    preferred_ids.each do |cid|
      vals = props
        .select { |p| p.character_codepoint_id == cid && p.field == "laoguoyin" }
        .map { |p| p.value.to_s.strip }
        .reject(&:blank?)

      next if vals.empty?

      # Format according to the currently selected ONP convention and
      # sort stably so the dropdown options are predictable.
      enriched = vals.map do |raw|
        parts = respond_to?(:split_laoguoyin_parts) ? split_laoguoyin_parts(raw) : { latin: nil, zhuyin: nil, ipa: nil }
        key =
          case scheme.to_sym
          when :latin
            parts[:latin].to_s
          when :zhuyin
            parts[:zhuyin].to_s
          when :ipa
            parts[:ipa].to_s
          else
            parts[:latin].to_s
          end

        display = if respond_to?(:format_laoguoyin_value)
          format_laoguoyin_value(raw, scheme: scheme).to_s.strip
        else
          raw.to_s.strip
        end

        next if display.blank?
        [key, display]
      end.compact

      enriched.sort_by! { |key, display| [key.to_s, display] }

      # De-dupe while preserving order after sort
      seen = {}
      out = []
      enriched.each do |(_key, display)|
        next if display.blank?
        next if seen[display]
        seen[display] = true
        out << display
      end

      return out
    end

    []
  end

  # Choose which ruby token to display, based on session[:ruby_token].
  # If the session token is missing or invalid, fall back to the first token.
  def pick_ruby_token_from_session(tokens)
    return nil if tokens.blank?
    desired = session[:ruby_token].to_s.strip
    return desired if desired.present? && tokens.include?(desired)
    tokens.first
  end

  # Fetch the "best" Unihan reading value for a given field name.
  # File: app/helpers/characters_helper.rb
  # Ordering logic is implemented in best_unihan_value_for.
  def preferred_unihan_reading(field_name:)
    best_unihan_value_for(field_name)
  end

  # Split a Unihan reading field into tokens (whitespace-separated).
  def split_unihan_tokens(raw)
    return [] if raw.blank?
    raw.to_s.strip.split(/\s+/).map(&:strip).reject(&:blank?)
  end

  # Split on whitespace and return the first non-empty token.
  def pick_first_token(raw)
    return nil if raw.blank?
    raw.to_s.strip.split(/\s+/).first.to_s.strip
  end

  # Japanese ruby helper:
  # - If there are multiple readings separated by spaces, take the first.
  # - If that reading contains "a/b", choose A or B using current_japanese_alt_index.
  # - If want_kana is true, keep kana as-is, otherwise attempt a basic romaji→kana conversion.
  def pick_japanese_token(raw, want_kana:)
    tok = pick_first_token(raw)
    return nil if tok.blank?

    parts = tok.split("/")
    chosen = (parts[current_japanese_alt_index] || parts.first).to_s.strip
    return nil if chosen.blank?

    if want_kana
      if chosen.match?(/[\p{Hiragana}\p{Katakana}]/)
        chosen
      else
        hepburn_to_kana(chosen)
      end
    else
      chosen
    end
  end
  # --- internals -------------------------------------------------------

  def best_unihan_value_for(field_name)
    # The controller builds @properties across the "family" of this character.
    # We'll use that list if it exists; otherwise, we give up quietly.
    props = @properties
    return nil unless props.respond_to?(:select)

    # Prefer: current -> base -> variants
    preferred_ids = []
    preferred_ids << @character&.id
    preferred_ids << @base_character&.id
    preferred_ids.concat(Array(@variant_characters).map(&:id))
    preferred_ids.compact!

    # Filter down to the field we care about.
    #
    # BUG FIX:
    # We store Unihan reading fields under source "Unihan_Readings" (not "Unihan").
    candidates = props.select { |p| UNIHAN_READING_SOURCES.include?(p.source) && p.field == field_name }
    return nil if candidates.empty?

    # Find the first value in preferred order.
    preferred_ids.each do |cid|
      v = candidates.find { |p| p.character_codepoint_id == cid }&.value
      return v if v.present?
    end

    # Last resort: any value.
    candidates.first&.value
  end

# --- Japanese (Hepburn) -> Kana (best-effort) ------------------------
# Covers common syllables; unknown chunks are left unchanged.
def hepburn_to_kana(romaji)
  return "" if romaji.blank?

  s = romaji.to_s.downcase

  table = {
    "kya"=>"きゃ","kyu"=>"きゅ","kyo"=>"きょ",
    "sha"=>"しゃ","shu"=>"しゅ","sho"=>"しょ",
    "cha"=>"ちゃ","chu"=>"ちゅ","cho"=>"ちょ",
    "nya"=>"にゃ","nyu"=>"にゅ","nyo"=>"にょ",
    "hya"=>"ひゃ","hyu"=>"ひゅ","hyo"=>"ひょ",
    "mya"=>"みゃ","myu"=>"みゅ","myo"=>"みょ",
    "rya"=>"りゃ","ryu"=>"りゅ","ryo"=>"りょ",
    "gya"=>"ぎゃ","gyu"=>"ぎゅ","gyo"=>"ぎょ",
    "bya"=>"びゃ","byu"=>"びゅ","byo"=>"びょ",
    "pya"=>"ぴゃ","pyu"=>"ぴゅ","pyo"=>"ぴょ",
    "ja"=>"じゃ","ju"=>"じゅ","jo"=>"じょ",

    "a"=>"あ","i"=>"い","u"=>"う","e"=>"え","o"=>"お",
    "ka"=>"か","ki"=>"き","ku"=>"く","ke"=>"け","ko"=>"こ",
    "sa"=>"さ","shi"=>"し","su"=>"す","se"=>"せ","so"=>"そ",
    "ta"=>"た","chi"=>"ち","tsu"=>"つ","te"=>"て","to"=>"と",
    "na"=>"な","ni"=>"に","nu"=>"ぬ","ne"=>"ね","no"=>"の",
    "ha"=>"は","hi"=>"ひ","fu"=>"ふ","he"=>"へ","ho"=>"ほ",
    "ma"=>"ま","mi"=>"み","mu"=>"む","me"=>"め","mo"=>"も",
    "ya"=>"や","yu"=>"ゆ","yo"=>"よ",
    "ra"=>"ら","ri"=>"り","ru"=>"る","re"=>"れ","ro"=>"ろ",
    "wa"=>"わ","wo"=>"を",
    "ga"=>"が","gi"=>"ぎ","gu"=>"ぐ","ge"=>"げ","go"=>"ご",
    "za"=>"ざ","ji"=>"じ","zu"=>"ず","ze"=>"ぜ","zo"=>"ぞ",
    "da"=>"だ","de"=>"で","do"=>"ど",
    "ba"=>"ば","bi"=>"び","bu"=>"ぶ","be"=>"べ","bo"=>"ぼ",
    "pa"=>"ぱ","pi"=>"ぴ","pu"=>"ぷ","pe"=>"ぺ","po"=>"ぽ"
  }

  out = +""
  i = 0
  while i < s.length
    ch = s[i]

    # Keep non-letters (spaces, punctuation, tone marks, etc.)
    if ch !~ /[a-z]/
      out << ch
      i += 1
      next
    end

    # Small っ for double consonants (kko, ssa, tta, etc.), excluding "nn".
    if i + 1 < s.length &&
       s[i] == s[i + 1] &&
       s[i] =~ /[bcdfghjklmnpqrstvwxyz]/ &&
       s[i] != "n"
      out << "っ"
      i += 1
      next
    end

    # 'n' before consonant or end of word -> ん
    if ch == "n"
      nxt = s[i + 1]
      if nxt.nil? || nxt !~ /[aeiouy]/
        out << "ん"
        i += 1
        next
      end
    end

    # Try longest match (3, then 2, then 1).
    chunk = nil
    [3, 2, 1].each do |len|
      cand = s[i, len]
      next unless table.key?(cand)
      chunk = cand
      break
    end

    if chunk
      out << table[chunk]
      i += chunk.length
    else
      out << ch
      i += 1
    end
  end

  out
end

end
