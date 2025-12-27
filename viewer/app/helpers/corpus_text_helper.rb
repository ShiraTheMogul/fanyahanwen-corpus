# frozen_string_literal: true

module CorpusTextHelper
  include PhoneticizationHelper

  UNIHAN_READING_SOURCES = ["Unihan_Readings", "Unihan"].freeze

  def corpus_text_with_optional_ruby(text)
    s = text.to_s
    return ERB::Util.html_escape(s).html_safe unless ruby_enabled_in_session?
    corpus_text_with_ruby(s)
  end

  private

  def ruby_enabled_in_session?
    v = session[:ruby_enabled]
    v == true || v.to_s == "true" || v.to_s == "1"
  end

  def current_ruby_source_sym
    (session[:ruby_source].presence || :mandarin).to_s.strip.downcase.tr(" ", "_").to_sym
  end

  def current_ruby_orientation_sym
    raw = session[:ruby_orientation].presence || :horizontal
    sym = raw.to_s.strip.downcase.to_sym
    sym = :vertical if sym == :verticalside
    [:horizontal, :vertical].include?(sym) ? sym : :horizontal
  end

  def current_ruby_side_sym
    raw = session[:ruby_side].presence || :right
    sym = raw.to_s.strip.downcase.to_sym
    [:right, :left].include?(sym) ? sym : :right
  end

  def corpus_ruby_class
    parts = ["ruby-annot", "ruby-#{current_ruby_orientation_sym}"]
    parts << "ruby-side-#{current_ruby_side_sym}" if current_ruby_orientation_sym == :vertical
    parts.join(" ")
  end

  def unique_han_chars(text)
    seen = {}
    text.each_char do |ch|
      next unless ch.match?(/\p{Han}/)
      seen[ch] = true
    end
    seen.keys
  end

  def ruby_field_name_for(source)
    case source
    when :mandarin then "kMandarin"
    when :cantonese then "kCantonese"
    when :japanese_kana then "kJapanese"
    when :japanese_on then "kJapaneseOn"
    when :japanese_kun then "kJapaneseKun"
    when :korean_yale then "kKorean"
    when :korean_hangul then "kHangul"
    when :vietnamese then "kVietnamese"
    when :zhuang then "kZhuang"
    when :fanqie then "kFanqie"
    when :tang then "kTang"
    else nil
    end
  end

  def format_ruby_token(source, field, tok)
    case source
    when :mandarin, :cantonese
      phoneticize_unihan_value(field, tok)
    when :japanese_kana
      return tok if tok.match?(/[\p{Hiragana}\p{Katakana}]/)
      respond_to?(:hepburn_to_kana, true) ? hepburn_to_kana(tok) : tok
    when :korean_hangul
      tok.to_s.sub(/[：:].*$/, "").strip
    else
      tok
    end
  rescue StandardError
    tok
  end
  def laoguoyin_reading_map(ids_by_chr, ids)
    scheme = current_laoguoyin_scheme rescue :latin

    rows = []
    ids.each_slice(500) do |id_slice|
      rows.concat(
        LaoguoyinReading.where(character_codepoint_id: id_slice)
                        .pluck(:character_codepoint_id, :laoguoyin, :zhuyin, :ipa)
      )
    end

    best = {}
    rows.each do |cid, latin, zhuyin, ipa|
      next if best.key?(cid)

      parts = []
      parts << latin.to_s.strip if latin.present?
      parts << zhuyin.to_s.strip if zhuyin.present?
      if ipa.present?
        ipa_s = ipa.to_s.strip
        ipa_s = "/#{ipa_s}/" unless ipa_s.start_with?("/")
        parts << ipa_s
      end

      raw = parts.join(" ")
      best[cid] = format_laoguoyin_value(raw, scheme: scheme)
    end

    out = {}
    ids_by_chr.each do |chr, cid|
      out[chr] = best[cid] if best[cid].present?
    end

    out
  rescue StandardError
    {}
  end
  def corpus_ruby_readings_for(chars)
    source = current_ruby_source_sym

    # Avoid DB parameter limits (SQLite famously caps at 999).
    ids_by_chr = {}
    chars.each_slice(500) do |slice|
      ids_by_chr.merge!(CharacterCodepoint.where(chr: slice).pluck(:chr, :id).to_h)
    end
    return {} if ids_by_chr.empty?

    ids = ids_by_chr.values

    if source == :laoguoyin
      return laoguoyin_reading_map(ids_by_chr, ids)
    end

    field = ruby_field_name_for(source)
    return {} if field.nil?

    rows = []
    ids.each_slice(500) do |id_slice|
      rows.concat(
        CharacterProperty
          .where(character_codepoint_id: id_slice, source: UNIHAN_READING_SOURCES, field: field)
          .pluck(:character_codepoint_id, :source, :value)
      )
    end

    source_rank = { "Unihan_Readings" => 0, "Unihan" => 1 }

    best_value = {}
    rows.sort_by { |cid, src, _v| [cid, source_rank[src] || 99] }.each do |cid, _src, v|
      best_value[cid] ||= v
    end

    out = {}
    ids_by_chr.each do |chr, cid|
      raw = best_value[cid].to_s
      tok = raw.strip.split(/\s+/).reject(&:blank?).first
      next if tok.blank?
      out[chr] = format_ruby_token(source, field, tok)
    end

    out
  rescue StandardError
    {}
  end


  def corpus_text_with_ruby(text)
    chars = unique_han_chars(text)
    return ERB::Util.html_escape(text).html_safe if chars.empty?

    readings = corpus_ruby_readings_for(chars)
    ruby_class = corpus_ruby_class

    buf = ActiveSupport::SafeBuffer.new

    text.each_char do |ch|
      reading = readings[ch]
      if reading.present?
        # IMPORTANT: SafeBuffer will *escape* unsafe strings appended via <<.
        # Use safe_concat for literal HTML tags, and keep user/DB content escaped.
        buf.safe_concat(%(<ruby class="#{ruby_class}">).html_safe)
        buf << ERB::Util.html_escape(ch)
        buf.safe_concat("<rt>".html_safe)
        buf << ERB::Util.html_escape(reading)
        buf.safe_concat("</rt></ruby>".html_safe)
      else
        buf << ERB::Util.html_escape(ch)
      end
    end

    buf
  end
end
