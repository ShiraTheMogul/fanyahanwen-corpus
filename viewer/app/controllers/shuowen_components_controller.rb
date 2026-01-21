# frozen_string_literal: true

class ShuowenComponentsController < ApplicationController
  DEFAULT_PER = 50
  MAX_PER = 200

  UNIHAN_READING_SOURCES = ["Unihan_Readings", "Unihan"].freeze
  UNIHAN_READING_FIELDS = {
    mandarin: "kMandarin",
    vietnamese: "kVietnamese",
    japanese: "kJapanese",
    korean: "kKorean",
    hangul: "kHangul"
  }.freeze

  before_action :load_component, only: [:show, :chars]
  before_action :load_pagination, only: [:show, :chars]

  def index
    @components = ShuowenComponent.order(:number)
  end

  def show
    base = CharacterComponentMembership.where(component_number: @component.number)
    @total = base.count(:all)
    @memberships_exist = CharacterComponentMembership.exists?

    @def_source = params[:def].to_s.strip
    @def_source = "unihan" unless %w[unihan shuowen].include?(@def_source)

    @component_codepoint = CharacterCodepoint.find_by(chr: @component.glyph)

    @component_unihan_def = nil
    @component_shuowen_entry = nil

    # Raw strings from Unihan (may contain multiple readings separated by whitespace).
    @component_readings = { mandarin: nil, vietnamese: nil, japanese: nil, korean: nil, hangul: nil }

    # Pre-parsed lists for display (so we don't show "everything at once").
    @component_japanese_pairs = [] # [{kana:, romaji:}, ...]
    @component_korean_pairs   = [] # [{roman:, hangul:}, ...]
    @component_variants = []

    return unless @component_codepoint

    ccid = @component_codepoint.id
    props = CharacterProperty.where(character_codepoint_id: ccid).to_a

    @component_unihan_def = props.find { |p| p.field == "kDefinition" }&.value
    @component_shuowen_entry = props.find { |p| p.field == "shuowen_entry" }&.value

    UNIHAN_READING_FIELDS.each do |k, field|
      @component_readings[k] =
        props.find { |p| p.field == field && UNIHAN_READING_SOURCES.include?(p.source.to_s) }&.value ||
        props.find { |p| p.field == field }&.value
    end

    @component_japanese_pairs = build_japanese_pairs(@component_readings[:japanese].to_s)
    @component_korean_pairs   = build_korean_pairs(@component_readings[:korean].to_s, @component_readings[:hangul].to_s)

    base_cp = @component_codepoint.codepoint
    mapped = VariantMapping.where(base_codepoint: base_cp).pluck(:variant_codepoint)

    compat = props.select { |p| p.field == "kCompatibilityVariant" }.map { |p| p.value.to_s.strip }.reject(&:empty?)
    compat_cps = []

    compat.each do |raw|
      raw.split(/[\s,;]+/).each do |tok|
        t = tok.strip
        next if t.empty?
        if t =~ /\AU\+[0-9A-Fa-f]{4,6}\z/
          compat_cps << t.sub(/\AU\+/i, "").to_i(16)
        elsif t.length == 1
          compat_cps << t.ord
        end
      end
    end

    cps = (mapped + compat_cps).compact.uniq - [base_cp]
    @component_variants =
      if cps.any?
        CharacterCodepoint.where(codepoint: cps).order(:codepoint).to_a
      else
        []
      end
  end

  def chars
    base = CharacterComponentMembership.where(component_number: @component.number)
    @total = base.count(:all)

    @def_source = params[:def].to_s.strip
    @def_source = "unihan" unless %w[unihan shuowen].include?(@def_source)

    @characters = CharacterComponentMembership
      .joins(:character_codepoint)
      .where(component_number: @component.number)
      .select("character_codepoints.*")
      .order("character_codepoints.codepoint ASC")
      .limit(@per)
      .offset((@page - 1) * @per)
      .to_a

    field = (@def_source == "shuowen") ? "shuowen_entry" : "kDefinition"
    ids = @characters.map(&:id)
    @defs = CharacterProperty.where(character_codepoint_id: ids, field: field).pluck(:character_codepoint_id, :value).to_h
  end

  private

  def load_component
    @component = ShuowenComponent.find_by!(number: params[:number].to_i)
  end

  def load_pagination
    per = params[:per].to_i
    per = DEFAULT_PER if per <= 0
    per = MAX_PER if per > MAX_PER
    @per = per

    page = params[:page].to_i
    page = 1 if page <= 0
    @page = page
  end

  # Pattern: split Unihan token strings on whitespace and "/" into stable tokens.
  # For X in Y: tokens = raw.to_s.split(/[\s\/]+/).reject(&:blank?)
  def split_reading_tokens(raw)
    raw.to_s.strip.split(/[\s\/]+/).map(&:strip).reject(&:blank?)
  end

  # Japanese: store kana token + romaji(token) as pairs, not the whole-string romaji.
  def build_japanese_pairs(raw)
    kana_tokens = split_reading_tokens(raw)
    return [] if kana_tokens.empty?

    kana_tokens.map do |kana|
      { kana: kana, romaji: kana_to_romaji_token(kana) }
    end
  end

  # Korean: pair romanisation tokens with hangul tokens.
  # Hangul tokens: clip at ":" (metadata begins), then keep only the Hangul part.
  def build_korean_pairs(roman_raw, hangul_raw)
    roman = split_reading_tokens(roman_raw)
    hangul_tokens = split_reading_tokens(hangul_raw).map { |t| t.split(":", 2).first.to_s }

    # Keep only tokens that actually contain Hangul characters.
    hangul = hangul_tokens.select { |t| t.match?(/[\uAC00-\uD7AF]/) }

    n = [roman.length, hangul.length].max
    pairs = []

    (0...n).each do |i|
      r = roman[i]
      h = hangul[i]
      next if r.blank? && h.blank?
      pairs << { roman: r.presence, hangul: h.presence }
    end

    pairs
  end

  # Kana romaji for a *single token*.
  def kana_to_romaji_token(token)
    s = token.to_s.strip
    return nil if s.empty?

    hira = {
      "あ"=>"a","い"=>"i","う"=>"u","え"=>"e","お"=>"o",
      "か"=>"ka","き"=>"ki","く"=>"ku","け"=>"ke","こ"=>"ko",
      "さ"=>"sa","し"=>"shi","す"=>"su","せ"=>"se","そ"=>"so",
      "た"=>"ta","ち"=>"chi","つ"=>"tsu","て"=>"te","と"=>"to",
      "な"=>"na","に"=>"ni","ぬ"=>"nu","ね"=>"ne","の"=>"no",
      "は"=>"ha","ひ"=>"hi","ふ"=>"fu","へ"=>"he","ほ"=>"ho",
      "ま"=>"ma","み"=>"mi","む"=>"mu","め"=>"me","も"=>"mo",
      "や"=>"ya","ゆ"=>"yu","よ"=>"yo",
      "ら"=>"ra","り"=>"ri","る"=>"ru","れ"=>"re","ろ"=>"ro",
      "わ"=>"wa","を"=>"o","ん"=>"n",
      "が"=>"ga","ぎ"=>"gi","ぐ"=>"gu","げ"=>"ge","ご"=>"go",
      "ざ"=>"za","じ"=>"ji","ず"=>"zu","ぜ"=>"ze","ぞ"=>"zo",
      "だ"=>"da","ぢ"=>"ji","づ"=>"zu","で"=>"de","ど"=>"do",
      "ば"=>"ba","び"=>"bi","ぶ"=>"bu","べ"=>"be","ぼ"=>"bo",
      "ぱ"=>"pa","ぴ"=>"pi","ぷ"=>"pu","ぺ"=>"pe","ぽ"=>"po",
      "ぁ"=>"a","ぃ"=>"i","ぅ"=>"u","ぇ"=>"e","ぉ"=>"o",
      "ゃ"=>"ya","ゅ"=>"yu","ょ"=>"yo",
      "ー"=>"-"
    }

    dig = {
      "きゃ"=>"kya","きゅ"=>"kyu","きょ"=>"kyo",
      "しゃ"=>"sha","しゅ"=>"shu","しょ"=>"sho",
      "ちゃ"=>"cha","ちゅ"=>"chu","ちょ"=>"cho",
      "にゃ"=>"nya","にゅ"=>"nyu","にょ"=>"nyo",
      "ひゃ"=>"hya","ひゅ"=>"hyu","ひょ"=>"hyo",
      "みゃ"=>"mya","みゅ"=>"myu","みょ"=>"myo",
      "りゃ"=>"rya","りゅ"=>"ryu","りょ"=>"ryo",
      "ぎゃ"=>"gya","ぎゅ"=>"gyu","ぎょ"=>"gyo",
      "じゃ"=>"ja","じゅ"=>"ju","じょ"=>"jo",
      "びゃ"=>"bya","びゅ"=>"byu","びょ"=>"byo",
      "ぴゃ"=>"pya","ぴゅ"=>"pyu","ぴょ"=>"pyo"
    }

    # katakana → hiragana
    s_hira = s.chars.map do |ch|
      code = ch.ord
      if code >= 0x30A1 && code <= 0x30F6
        (code - 0x60).chr(Encoding::UTF_8)
      else
        ch
      end
    end.join

    out = +""
    i = 0
    while i < s_hira.length
      if s_hira[i] == "っ"
        nxt = s_hira[i+1,2]
        roma = dig[nxt] || hira[s_hira[i+1]]
        out << roma[0] if roma && roma.length > 0
        i += 1
        next
      end

      pair = s_hira[i,2]
      if dig.key?(pair)
        out << dig[pair]
        i += 2
        next
      end

      one = s_hira[i]
      out << (hira[one] || one)
      i += 1
    end

    out.strip
  end
end
