# encoding: UTF-8
# frozen_string_literal: true

# Laoguoyin 老国音 is a constructed topolect of Mandarin created by Yuen Ren Chao 赵元任. 
# It was meant to be the court dialect of China during the Republican era but it failed to catch on after around a decade of pushing.
# Wikiversity has transcribed the relevant dictionary and Latinised the Zhuyin script. 
# I intend to use this in my data. 

require "net/http"
require "json"
require "uri"
require "csv"
require "optparse"
require "set"

API = "https://zh.wikiversity.org/w/api.php"

# ----------------------------
# Fetch stable wikitext (no HTML scraping)
# ----------------------------
def fetch_wikitext(page_title)
  uri = URI(API)
  uri.query = URI.encode_www_form(
    action: "query",
    format: "json",
    formatversion: "2",
    prop: "revisions",
    rvprop: "content",
    rvslots: "main",
    titles: page_title
  )

  req = Net::HTTP::Get.new(uri)
  req["User-Agent"] = "scrape_laoguoyin_all/2.0 (personal script)"

  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
  raise "HTTP #{res.code} fetching #{page_title}" unless res.is_a?(Net::HTTPSuccess)

  data = JSON.parse(res.body)
  page = data.dig("query", "pages", 0)
  raise "Page not found: #{page_title}" if page.nil? || page["missing"]

  content = page.dig("revisions", 0, "slots", "main", "content")
  raise "No wikitext content found for #{page_title}" if content.nil? || content.empty?
  content
end

def codepoint_uplus(ch)
  format("U+%04X", ch.ord)
end

# ----------------------------
# Token normalization + gating
# ----------------------------
def normalize_token(raw)
  s = raw.to_s.strip.downcase

  # unify entering tone marker q -> 5 (riwq -> riw5)
  s = s.sub(/q\z/, "5") if s.length > 1

  # remove editorial markers seen in examples
  s = s.delete("`")
  s = s.delete("'")

  s
end

# some of the scrapes sucked so lets get rid of the junk
def looks_like_syllable?(tok)
  # roman letters + optional tone digit
  !!(tok =~ /\A[a-z]+[1-5]?\z/)
end

# Pull syllable-like tokens out of "( ... )", then normalize + filter.
def extract_syllables(inside_parens, initial_keys_desc: nil, noise_counter: nil)
  s = inside_parens.dup

  # drop anything after "=" (annotation style)
  s = s.split("=").first

  raw = s.scan(/`?[a-z]+(?:'[a-z]+)*[0-5]?q?/i)
  tokens = []

  raw.each do |t|
    nt = normalize_token(t)
    next if nt.empty?

    # Reject obvious non-syllable junk early.
    # - lone 'q' used in prose notes should not become a fake '5' token
    # - very long words are almost certainly citations / prose (e.g. Bernick)
    if nt.match?(/\A[1-5]\z/)
      noise_counter[nt] += 1 if noise_counter
      next
    end
    if nt.length > 10
      noise_counter[nt] += 1 if noise_counter
      next
    end

    unless looks_like_syllable?(nt)
      noise_counter[nt] += 1 if noise_counter
      next
    end

    # If there is no explicit tone digit, only keep it if it can be converted.
    # This keeps real neutral-tone tokens (e.g. zhi) but drops prose words.
    if nt !~ /[1-5]\z/ && initial_keys_desc
      unless roman_to_zhuyin(nt, initial_keys_desc)
        noise_counter[nt] += 1 if noise_counter
        next
      end
    end

    tokens << nt
  end

  tokens
end

# ----------------------------
# Zhuyin conversion (basic, with your fixes)
# ----------------------------
INITIAL_ZHUYIN = {
  "ng"=>"ㄫ", "nj"=>"ㄬ",
  "zh"=>"ㄓ", "ch"=>"ㄔ", "sh"=>"ㄕ",
  "b"=>"ㄅ","p"=>"ㄆ","m"=>"ㄇ","f"=>"ㄈ","v"=>"ㄪ",
  "d"=>"ㄉ","t"=>"ㄊ","n"=>"ㄋ","l"=>"ㄌ",
  "g"=>"ㄍ","k"=>"ㄎ","h"=>"ㄏ",
  "j"=>"ㄐ","q"=>"ㄑ","x"=>"ㄒ",
  "r"=>"ㄖ",
  "z"=>"ㄗ","c"=>"ㄘ","s"=>"ㄙ",
  "yu"=>"ㄩ", "y"=>"ㄧ", "w"=>"ㄨ"
}.freeze

FINAL_ZHUYIN = {
  # ü- series written variously
  "yuo"=>"ㄩㄛ", "ueo"=>"ㄩㄛ",
  "yue"=>"ㄩㄝ", "ue"=>"ㄩㄝ",
  "yuan"=>"ㄩㄢ", "yun"=>"ㄩㄣ", "yung"=>"ㄩㄥ",

  # apical vowel
  "iw"=>"ㄭ",

  # common finals
  "iang"=>"ㄧㄤ", "ing"=>"ㄧㄥ", "uang"=>"ㄨㄤ", "ung"=>"ㄨㄥ", "eng"=>"ㄥ", "ang"=>"ㄤ",
  "ian"=>"ㄧㄢ", "in"=>"ㄧㄣ", "uan"=>"ㄨㄢ", "un"=>"ㄨㄣ", "en"=>"ㄣ", "an"=>"ㄢ",
  "iau"=>"ㄧㄠ", "ieu"=>"ㄧㄡ", "iai"=>"ㄧㄞ", "ia"=>"ㄧㄚ", "io"=>"ㄧㄛ", "ie"=>"ㄧㄝ",
  "uai"=>"ㄨㄞ", "uei"=>"ㄨㄟ", "ua"=>"ㄨㄚ", "uo"=>"ㄨㄛ",
  "ai"=>"ㄞ", "ei"=>"ㄟ", "au"=>"ㄠ", "eu"=>"ㄡ",
  "a"=>"ㄚ", "o"=>"ㄛ", "eo"=>"ㄜ", "e"=>"ㄝ",
  "i"=>"ㄧ", "u"=>"ㄨ", "yu"=>"ㄩ",
  "yi"=>"ㄧ",
  "er"=>"ㄦ"
}.freeze

# fsr the page did this
SPECIAL_WHOLE = {
  "yi" => "ㄧ",
  "wu" => "ㄨ",
  "yu" => "ㄩ"
}.freeze

def split_tone(tok)
  if tok =~ /([1-5])\z/
    [tok[0...-1], Regexp.last_match(1)]
  else
    [tok, nil]
  end
end

def split_initial_final(base, initial_keys_desc)
  ini = ""
  fin = base
  initial_keys_desc.each do |k|
    next unless base.start_with?(k)
    ini = k
    fin = base[k.length..] || ""
    break
  end
  [ini, fin]
end

def roman_to_zhuyin(raw_tok, initial_keys_desc)
  tok = normalize_token(raw_tok)
  return nil if tok.empty?
  return nil unless looks_like_syllable?(tok)

  base, tone = split_tone(tok)

  # whole syllables (avoid y+i double-count)
  if SPECIAL_WHOLE.key?(base)
    zy = SPECIAL_WHOLE[base]
    return tone ? "#{zy}#{tone}" : zy
  end

  # erhua final: ...r means add ㄦ (except er itself)
  erhua = false
  if base.end_with?("r") && base != "er"
    erhua = true
    base = base[0...-1]
  end

  ini, fin = split_initial_final(base, initial_keys_desc)

  ini_zy = ini.empty? ? "" : INITIAL_ZHUYIN[ini]
  return nil if !ini.empty? && ini_zy.nil?

  # allow syllables like "ng" (ini="ng", fin="")
  fin_zy =
    if fin.empty?
      ""
    else
      FINAL_ZHUYIN[fin]
    end
  return nil if !fin.empty? && fin_zy.nil?

  # apical vowel special: zhi/chi/shi/ri/zi/ci/si + i -> ㄭ
  if %w[zh ch sh r z c s].include?(ini) && fin == "i"
    fin_zy = "ㄭ"
  end

  zy = "#{ini_zy}#{fin_zy}"
  zy += "ㄦ" if erhua
  zy += tone.to_s if tone
  zy
end

# ----------------------------
# IPA annotation (from Zhuyin; partial, blanks allowed)
# ----------------------------
INITIAL_IPA = {
  "ㄅ"=>"p", "ㄆ"=>"pʰ", "ㄇ"=>"m", "ㄈ"=>"f", "ㄪ"=>"ʋ",
  "ㄉ"=>"t", "ㄊ"=>"tʰ", "ㄋ"=>"n", "ㄌ"=>"l",
  "ㄍ"=>"k", "ㄎ"=>"kʰ", "ㄏ"=>"x",
  "ㄐ"=>"tɕ", "ㄑ"=>"tɕʰ", "ㄒ"=>"ɕ",
  "ㄓ"=>"ʈʂ", "ㄔ"=>"ʈʂʰ", "ㄕ"=>"ʂ", "ㄖ"=>"ʐ",
  "ㄗ"=>"ts", "ㄘ"=>"tsʰ", "ㄙ"=>"s",
  "ㄫ"=>"ŋ", "ㄬ"=>"ɲ"
}.freeze

FINAL_IPA = {
  "ㄭ"=>"ɨ", "ㄧ"=>"i", "ㄨ"=>"u", "ㄩ"=>"y",
  "ㄚ"=>"a", "ㄛ"=>"ɔ", "ㄜ"=>"ɤ", "ㄝ"=>"ɛ",
  "ㄞ"=>"aɪ", "ㄟ"=>"eɪ", "ㄠ"=>"ɑʊ", "ㄡ"=>"oʊ",
  "ㄢ"=>"an", "ㄣ"=>"ən", "ㄤ"=>"ɑŋ", "ㄥ"=>"əŋ", "ㄦ"=>"əɻ",
  "ㄧㄡ"=>"iɔʊ", "ㄨㄥ"=>"ʊŋ", "ㄩㄥ"=>"yŋ", "ㄩㄝ"=>"yɛ", "ㄩㄛ"=>"yɔ",
  "ㄧㄢ"=>"iɛn", "ㄧㄣ"=>"in", "ㄨㄢ"=>"uan", "ㄨㄣ"=>"uən",
  "ㄧㄠ"=>"iɑʊ", "ㄧㄚ"=>"iɑ", "ㄧㄛ"=>"iɔ", "ㄧㄝ"=>"iɛ",
  "ㄨㄚ"=>"uɑ", "ㄨㄛ"=>"uɔ", "ㄨㄞ"=>"uaɪ", "ㄨㄟ"=>"ueɪ"
}.freeze

def zhuyin_to_ipa(zy)
  return nil if zy.nil? || zy.empty?

  tone = zy[-1] =~ /[1-5]/ ? zy[-1] : nil
  core = tone ? zy[0...-1] : zy

  first = core[0]
  if INITIAL_IPA.key?(first)
    ini = first
    fin = core[1..] || ""
  else
    ini = ""
    fin = core
  end

  ini_ipa = ini.empty? ? "" : INITIAL_IPA[ini]
  fin_ipa = fin.empty? ? "" : FINAL_IPA[fin]
  return nil if !fin.empty? && fin_ipa.nil?

  out = "#{ini_ipa}#{fin_ipa}"
  out += tone.to_s if tone
  out
end

# ----------------------------
# Extract both shapes
# ----------------------------
def extract_rows(text, initial_keys_desc:, noise_counter:)
  rows = []
  stats = {
    han_first_hits: 0,
    pron_first_hits: 0,
    multi_aligned: 0,
    multi_mismatch_skipped: 0,
    pron_tokens_dropped_as_noise: 0
  }

  # A) Han-first: 漢字（syll syll...）
  text.scan(/([〇\p{Han}]+)\s*[（(]([^）)]+)[）)]/) do |han_str, pron_block|
    stats[:han_first_hits] += 1
    chars = han_str.each_char.to_a
    sylls = extract_syllables(pron_block, initial_keys_desc: initial_keys_desc, noise_counter: noise_counter)

    if chars.length == 1
      next if sylls.empty?
      rows << [chars[0], sylls[0]]
    else
      if sylls.length == chars.length
        stats[:multi_aligned] += 1
        chars.each_with_index { |ch, i| rows << [ch, sylls[i]] }
      else
        stats[:multi_mismatch_skipped] += 1
      end
    end
  end

  # B) Pron-first: syll（漢字漢字…）
  text.scan(/([a-zA-Z`']+[0-5]?q?)\s*[（(]([〇\p{Han}]+)[）)]/) do |raw_syll, han_str|
    stats[:pron_first_hits] += 1

    syll = normalize_token(raw_syll)

    # Early junk filters (citations / prose / lone markers)
    if syll.empty? || syll.match?(/\A[1-5]\z/) || syll.length > 10
      noise_counter[syll] += 1 if !syll.empty?
      stats[:pron_tokens_dropped_as_noise] += 1
      next
    end

    unless looks_like_syllable?(syll)
      noise_counter[syll] += 1 if !syll.empty?
      stats[:pron_tokens_dropped_as_noise] += 1
      next
    end

    # No tone digit: keep only if convertible (prevents Bernick / issue, etc.)
    if syll !~ /[1-5]\z/
      unless roman_to_zhuyin(syll, initial_keys_desc)
        noise_counter[syll] += 1 if !syll.empty?
        stats[:pron_tokens_dropped_as_noise] += 1
        next
      end
    end

    han_str.each_char { |ch| rows << [ch, syll] }
  end

  rows.uniq!
  [rows, stats]
end

# ----------------------------
# Template transclusion: append known template(s)
# ----------------------------
def expand_known_templates(text, fetcher:, allow_templates:)
  allow_templates.each do |tpl_title|
    short = tpl_title.sub(/\ATemplate:/, "")
    if text.include?("{{#{tpl_title}}}") || text.include?("{{#{short}}}")
      text = text + "\n\n" + fetcher.call(tpl_title)
    end
  end
  text
end

# ----------------------------
# CLI
# ----------------------------
options = {
  pages: ["老國音學習", "整合老國音熟字彙"],
  out: "laoguoyin_merged.csv",
  zhuyin: true,
  ipa: true,
  codepoint: true,
  require_zhuyin: false # set true to drop rows whose zhuyin cannot be computed
}

OptionParser.new do |opts|
  opts.banner = "Usage: ruby scrape_laoguoyin_all.rb [options]"
  opts.on("--pages x,y", Array, "Page titles (default: #{options[:pages].join(', ')})") { |v| options[:pages] = v }
  opts.on("--out PATH", "Output CSV (default: #{options[:out]})") { |v| options[:out] = v }
  opts.on("--[no-]zhuyin", "Include zhuyin column (default: #{options[:zhuyin]})") { |v| options[:zhuyin] = v }
  opts.on("--[no-]ipa", "Include IPA column (default: #{options[:ipa]})") { |v| options[:ipa] = v }
  opts.on("--[no-]codepoint", "Include codepoint column (default: #{options[:codepoint]})") { |v| options[:codepoint] = v }
  opts.on("--require-zhuyin", "Drop rows where zhuyin is blank (default: #{options[:require_zhuyin]})") { options[:require_zhuyin] = true }
end.parse!

KNOWN_TEMPLATES = ["Template:老國音/新詩韻"].freeze
fetcher = ->(title) { fetch_wikitext(title) }

initial_keys_desc = INITIAL_ZHUYIN.keys.sort_by { |k| -k.length }

all_pairs = Set.new
global_stats = Hash.new(0)
noise_counter = Hash.new(0)

options[:pages].each do |title|
  text = fetcher.call(title)
  text = expand_known_templates(text, fetcher: fetcher, allow_templates: KNOWN_TEMPLATES)

  rows, stats = extract_rows(text, initial_keys_desc: initial_keys_desc, noise_counter: noise_counter)
  stats.each { |k, v| global_stats[k] += v }

  rows.each { |ch, pron| all_pairs.add([ch, pron]) }
end

sorted = all_pairs.to_a.sort_by { |ch, pron| [ch.ord, pron] }

# Audit summary (like your run output)
unique_chars = sorted.map { |ch, _| ch }.uniq.size
pairs_count = sorted.size
polyphones = sorted.group_by { |ch, _| ch }.select { |_, rows| rows.size > 1 }

missing_zhuyin = 0
top_unknown_finals = []

if options[:zhuyin]
  unknown_finals = Hash.new(0)

  sorted.each do |_, pron|
    zy = roman_to_zhuyin(pron, initial_keys_desc)
    if zy.nil?
      base, _tone = split_tone(normalize_token(pron))
      ini, fin = split_initial_final(base.end_with?("r") && base != "er" ? base[0...-1] : base, initial_keys_desc)
      unknown_finals[fin] += 1
      missing_zhuyin += 1
    end
  end

  top_unknown_finals = unknown_finals.sort_by { |_, c| -c }.first(30)
end

warn "Unique chars: #{unique_chars}"
warn "Pairs: #{pairs_count}"
warn "Chars with 2+ readings: #{polyphones.size}"
warn "Rows with blank zhuyin: #{missing_zhuyin}" if options[:zhuyin]
if options[:zhuyin] && !top_unknown_finals.empty?
  warn "Top unknown finals:"
  top_unknown_finals.each { |fin, c| warn "  #{fin.inspect}: #{c}" }
end
warn "Noise tokens (top 15):"
noise_counter.sort_by { |_, c| -c }.first(15).each { |tok, c| warn "  #{tok.inspect}: #{c}" }
warn "Stats: #{global_stats.inspect}"

# Write CSV
headers = ["character", "laoguoyin"]
headers << "zhuyin" if options[:zhuyin]
headers << "ipa" if options[:ipa]
headers << "codepoint" if options[:codepoint]

CSV.open(options[:out], "w", encoding: "UTF-8", write_headers: true, headers: headers) do |csv|
  sorted.each do |ch, pron|
    zy = options[:zhuyin] ? roman_to_zhuyin(pron, initial_keys_desc) : nil
    next if options[:require_zhuyin] && options[:zhuyin] && zy.nil?

    ipa = options[:ipa] ? zhuyin_to_ipa(zy) : nil

    row = [ch, pron]
    row << zy if options[:zhuyin]
    row << ipa if options[:ipa]
    row << codepoint_uplus(ch) if options[:codepoint]
    csv << row
  end
end

puts "Wrote #{sorted.length} unique (character, laoguoyin) pairs to #{options[:out]}"
puts "Note: use --require-zhuyin to drop the remaining conversion stragglers."
