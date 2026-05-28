#!/usr/bin/env ruby
# frozen_string_literal: true

# Build a reviewable han/domain manifest for the Fanya Hanwen corpus.
#
# v7 design:
# - Avoids the MediaWiki API by default. This prevents the 429 problem caused by
#   repeated /w/api.php calls.
# - Fetches only ordinary page/raw URLs unless you explicitly provide local files.
# - Uses the English List of han as the date source.
# - Uses Japanese names from:
#     1. manual overrides TSV
#     2. cached/non-API English page HTML -> Japanese alternate-link title
#     3. Japanese names visible in the English page HTML
#     4. local Japanese 藩の一覧 parsing when the Japanese page title matches
# - Never creates romanised folder names. Missing display names are blank and
#   marked for review.
#
# This script writes TSV only. It does not create folders.

require "cgi"
require "csv"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "optparse"
require "set"
require "uri"

PERIODS = [
  ["鎌倉時代", 1185, 1333],
  ["室町時代", 1336, 1573],
  ["安土桃山時代", 1573, 1603],
  ["江戸時代", 1603, 1868],
  ["明治時代", 1868, 1912]
].freeze

DEFAULTS = {
  english_title: "List of han",
  japanese_title: "藩の一覧",
  output: "han_manifest_from_wikipedia_v7.tsv",
  review_output: "han_manifest_review_rows_v7.tsv",
  japanese_names_output: "han_japanese_names_v7.tsv",
  type: "藩",
  date_basis: "polity",
  fetch_english: false,
  fetch_japanese: false,
  resolve_html_langlinks: true,
  include_missing_names: true,
  sleep_seconds: 2.0,
  max_retries: 6,
  start_cooldown: 0.0,
  cache_dir: ".han_manifest_cache",
  user_agent: "FanyaHanwenCorpusHanManifest/0.7 (local research script; set --user-agent with project URL or email)",
  verbose: false,
  overrides: nil,
  max_html_pages: nil
}.freeze

options = DEFAULTS.dup

OptionParser.new do |opts|
  opts.banner = "Usage: ruby build_han_manifest_v7_no_api_skip_404.rb [options]"

  opts.on("--english PATH", "Local English page source / pasted text / raw wikitext") { |v| options[:english] = v }
  opts.on("--japanese PATH", "Local Japanese page source / pasted text / raw wikitext") { |v| options[:japanese] = v }
  opts.on("--fetch-english", "Fetch English page source using non-API raw URL") { options[:fetch_english] = true }
  opts.on("--fetch-japanese", "Fetch Japanese page source using non-API raw URL") { options[:fetch_japanese] = true }
  opts.on("--english-title TITLE", "English Wikipedia page title") { |v| options[:english_title] = v }
  opts.on("--japanese-title TITLE", "Japanese Wikipedia page title") { |v| options[:japanese_title] = v }
  opts.on("--date-basis MODE", "polity, de-jure, or all. Default: polity") { |v| options[:date_basis] = v }
  opts.on("--overrides PATH", "Optional TSV: english_page_title or english_name -> display_name") { |v| options[:overrides] = v }
  opts.on("--no-html-langlinks", "Do not fetch English domain pages for Japanese alternate-link titles") { options[:resolve_html_langlinks] = false }
  opts.on("--drop-missing-names", "Do not write rows where no Japanese name was found") { options[:include_missing_names] = false }
  opts.on("--request-delay SECONDS", Float, "Minimum seconds between live HTTP requests. Default: 2.0") { |v| options[:sleep_seconds] = v }
  opts.on("--start-cooldown SECONDS", Float, "Sleep before first live request. Default: 0") { |v| options[:start_cooldown] = v }
  opts.on("--max-retries N", Integer, "Retry failed/429 requests this many times. Default: 6") { |v| options[:max_retries] = v }
  opts.on("--cache-dir PATH", "HTTP cache directory. Default: .han_manifest_cache") { |v| options[:cache_dir] = v }
  opts.on("--user-agent TEXT", "User-Agent with contact info") { |v| options[:user_agent] = v }
  opts.on("--verbose", "Print each live request/cache hit") { options[:verbose] = true }
  opts.on("--max-html-pages N", Integer, "Debug limit for English-domain HTML enrichment") { |v| options[:max_html_pages] = v }
  opts.on("--output PATH", "Main manifest TSV") { |v| options[:output] = v }
  opts.on("--review-output PATH", "Rows needing review TSV") { |v| options[:review_output] = v }
  opts.on("--japanese-names-output PATH", "Parsed Japanese list TSV") { |v| options[:japanese_names_output] = v }
end.parse!

unless %w[polity de-jure all].include?(options[:date_basis])
  warn "--date-basis must be one of: polity, de-jure, all"
  exit 1
end

# ---------- non-API HTTP helper ----------

class HttpRequestError < StandardError
  attr_reader :code, :retry_after

  def initialize(message, code: nil, retry_after: nil)
    super(message)
    @code = code
    @retry_after = retry_after
  end
end

class PoliteHttp
  def initialize(delay_seconds:, retries:, user_agent:, cache_dir:, verbose: false)
    @delay_seconds = delay_seconds.to_f
    @retries = retries.to_i
    @user_agent = user_agent
    @cache_dir = cache_dir
    @verbose = verbose
    @last_live_request_at = nil
    FileUtils.mkdir_p(@cache_dir)
  end

  def get(url, context: nil)
    cache_path = cache_path_for(url)
    if File.exist?(cache_path)
      warn "Cache hit: #{context || url}" if @verbose
      return decode_utf8(File.binread(cache_path))
    end

    attempts = 0
    begin
      attempts += 1
      sleep_before_live_request(context || url)
      warn "Requesting #{context || url}" if @verbose

      uri = URI(url)
      req = Net::HTTP::Get.new(uri)
      req["User-Agent"] = @user_agent
      req["Accept"] = "text/html, text/plain, */*"

      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: 45, open_timeout: 20) do |http|
        http.request(req)
      end
      @last_live_request_at = Time.now
      warn "Finished #{context || url} -> HTTP #{res.code}" if @verbose

      unless res.is_a?(Net::HTTPSuccess)
        raise HttpRequestError.new(
          "HTTP #{res.code}: #{res.body.to_s[0, 300]}",
          code: res.code.to_i,
          retry_after: retry_after_seconds(res)
        )
      end

      body = decode_utf8(res.body.to_s)
      File.binwrite(cache_path, body.encode("UTF-8"))
      body
    rescue StandardError => e
      # Missing pages are normal during optional enrichment. Do not retry them.
      # Example: a parsed/source-derived title like "Tokugawa period Domain" may not
      # exist as an English Wikipedia page. The caller can catch this and mark the
      # row for manual review instead of wasting requests.
      if e.respond_to?(:code) && [404, 410].include?(e.code.to_i)
        raise e
      end

      raise e unless attempts < @retries

      delay = if e.respond_to?(:code) && e.code == 429
                e.retry_after ? e.retry_after.to_f + 1.0 : [@delay_seconds * attempts * 8, 90].min
              else
                [@delay_seconds * attempts, 20].min
              end
      warn "Request failed for #{context || url} (#{e.message.lines.first&.strip}); retrying in #{format('%.1f', delay)}s (attempt #{attempts}/#{@retries})"
      sleep delay if delay.positive?
      retry
    end
  end

  private

  def sleep_before_live_request(context)
    return unless @last_live_request_at && @delay_seconds.positive?

    elapsed = Time.now - @last_live_request_at
    remaining = @delay_seconds - elapsed
    if remaining.positive?
      warn "Sleeping #{format('%.1f', remaining)}s before #{context}" if @verbose
      sleep remaining
    end
  end

  def retry_after_seconds(response)
    header = response["retry-after"].to_s.strip
    return nil if header.empty?
    Integer(header, exception: false)
  end

  def decode_utf8(raw)
    text = raw.to_s.dup
    text.force_encoding("UTF-8")
    return text if text.valid_encoding?

    text.scrub("�")
  end

  def cache_path_for(url)
    File.join(@cache_dir, Digest::SHA256.hexdigest(url) + ".txt")
  end
end

def wiki_host(wiki)
  case wiki
  when :en then "en.wikipedia.org"
  when :ja then "ja.wikipedia.org"
  else raise "Unknown wiki: #{wiki.inspect}"
  end
end

def wiki_raw_url(wiki, title)
  host = wiki_host(wiki)
  encoded_title = URI.encode_www_form_component(title)
  "https://#{host}/w/index.php?title=#{encoded_title}&action=raw"
end

def wiki_page_url(wiki, title)
  host = wiki_host(wiki)
  path_title = title.to_s.tr(" ", "_")
  encoded = path_title.split("/").map { |p| URI.encode_www_form_component(p) }.join("/")
  "https://#{host}/wiki/#{encoded}"
end

def read_source(path, fetch:, wiki:, title:, http:)
  if path
    raw = File.binread(path)
    raw.force_encoding("UTF-8")
    raw.valid_encoding? ? raw : raw.scrub("�")
  elsif fetch
    http.get(wiki_raw_url(wiki, title), context: "fetch raw #{wiki}:#{title}")
  else
    nil
  end
end

# ---------- text helpers ----------

def unwrap_source(text)
  parsed = JSON.parse(text)
  return parsed.dig("parse", "wikitext", "*") if parsed.dig("parse", "wikitext", "*")

  pages = parsed.dig("query", "pages")
  if pages.is_a?(Array) && pages.first
    rev = pages.first.dig("revisions", 0)
    return rev.dig("slots", "main", "content") if rev&.dig("slots", "main", "content")
    return rev["content"] if rev && rev["content"]
  end
  text
rescue JSON::ParserError
  text
end

def clean_wiki_label(text)
  return "" if text.nil?

  cleaned = text.dup
  cleaned.gsub!(/<ref[^>]*>.*?<\/ref>/m, "")
  cleaned.gsub!(/<ref[^\/]*\/>/, "")
  cleaned.gsub!(/\{\{[^{}]*\}\}/, "")
  cleaned.gsub!(/'''|''/, "")
  cleaned.gsub!(/\[\[([^\]|#]+)(?:#[^\]|]*)?\|([^\]]+)\]\]/, "\\2")
  cleaned.gsub!(/\[\[([^\]|#]+)(?:#[^\]]*)?\]\]/, "\\1")
  cleaned.gsub!(/\[[0-9]+\]/, "")
  cleaned.gsub!(/&nbsp;/, " ")
  cleaned.strip
end

def normalize_dash(text)
  text.to_s.tr("–—−〜～", "-----")
end

def strip_domain_suffix(name)
  name.to_s
      .sub(/\s+Domain\z/i, "")
      .sub(/\s+domain\z/i, "")
      .strip
end

def japanese_text?(text)
  !!(text.to_s =~ /\p{Han}|\p{Hiragana}|\p{Katakana}/)
end

def extract_japanese_han_name(text)
  candidates = text.to_s.scan(/[\p{Han}\p{Hiragana}\p{Katakana}々ヶー・]{2,25}藩/)
  candidates.reject! { |c| c.include?("日本") && c.length > 6 }
  candidates.reject! { |c| c =~ /一覧|各地|存在|明治時代|江戸時代|藩主|藩庁|支藩|諸藩/ }
  candidates.first
end

def main_japanese_name(raw)
  clean = clean_wiki_label(raw)
  clean.split(/[（(＜<]/).first.to_s.strip
end

def slugify_id(label)
  ascii = label.to_s.unicode_normalize(:nfkd).encode("ASCII", invalid: :replace, undef: :replace, replace: "")
  slug = ascii.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "")
  slug.empty? ? "unnamed" : slug
end

def html_attr(tag, name)
  tag[/\b#{Regexp.escape(name)}\s*=\s*"([^"]*)"/i, 1] || tag[/\b#{Regexp.escape(name)}\s*=\s*'([^']*)'/i, 1]
end

def html_text_loose(html)
  html.to_s.gsub(/<script\b.*?<\/script>/mi, " ")
          .gsub(/<style\b.*?<\/style>/mi, " ")
          .gsub(/<[^>]+>/, " ")
          .gsub(/&nbsp;/, " ")
          .gsub(/&amp;/, "&")
          .gsub(/\s+/, " ")
          .strip
end

def ja_title_from_html_alternate(html)
  html.to_s.scan(/<link\b[^>]*>/i).each do |tag|
    rel = html_attr(tag, "rel").to_s
    hreflang = html_attr(tag, "hreflang").to_s
    href = html_attr(tag, "href").to_s
    next unless rel.split(/\s+/).include?("alternate")
    next unless hreflang == "ja"
    next unless href.include?("//ja.wikipedia.org/wiki/")

    title = href.split("/wiki/", 2)[1].to_s
    title = title.split(/[?#]/, 2).first
    return CGI.unescape(title).tr("_", " ") unless title.empty?
  end

  # Fallback for language-link anchors when the alternate <link> is absent.
  html.to_s.scan(/<a\b[^>]*>/i).each do |tag|
    hreflang = html_attr(tag, "hreflang").to_s
    href = html_attr(tag, "href").to_s
    next unless hreflang == "ja"
    next unless href.include?("//ja.wikipedia.org/wiki/")

    title = href.split("/wiki/", 2)[1].to_s
    title = title.split(/[?#]/, 2).first
    return CGI.unescape(title).tr("_", " ") unless title.empty?
  end

  nil
end

# ---------- date parsing ----------

def date_intervals_from(text)
  normalize_dash(text).scan(/(\d{3,4})\s*-+\s*(\d{3,4})/).map { |a, b| [a.to_i, b.to_i] }
end

def parse_date_expression(raw, date_basis: "polity")
  normalized = normalize_dash(raw)
  notes = []
  return { selected: [], all: [], notes: ["unknown_dates"] } if normalized =~ /unknown dates|dates unknown/i

  all_intervals = date_intervals_from(normalized)
  de_facto = normalized[/de\s*facto\s*:?\s*([^\/]+)/i, 1]
  de_jure  = normalized[/de\s*jure\s*:?\s*([^\/]+)/i, 1]

  selected = case date_basis
             when "de-jure"
               if de_jure
                 notes << "selected_de_jure_dates"
                 date_intervals_from(de_jure)
               else
                 all_intervals
               end
             when "all"
               all_intervals
             else
               if de_facto
                 notes << "selected_de_facto_dates"
                 date_intervals_from(de_facto)
               elsif de_jure
                 notes << "selected_de_jure_dates_no_de_facto_available"
                 date_intervals_from(de_jure)
               else
                 all_intervals
               end
             end

  notes << "no_parseable_date_range" if selected.empty?
  selected.each do |start_year, end_year|
    notes << "suspicious_start_after_end" if start_year > end_year
    notes << "suspicious_end_year_#{end_year}" if end_year > 1912
    notes << "suspicious_start_year_#{start_year}" if start_year < 1185
  end
  { selected: selected, all: all_intervals, notes: notes.uniq }
end

def periods_for(interval)
  start_year, end_year = interval
  PERIODS.select do |_period, period_start, period_end|
    start_year < period_end && end_year > period_start
  end.map(&:first)
end

# ---------- source parsers ----------

def parse_english_entries(source_text, date_basis: "polity")
  text = unwrap_source(source_text)
  entries = []
  region = nil
  province = nil

  text.each_line do |line|
    raw_line = line.chomp
    stripped = raw_line.strip
    next if stripped.empty?

    if (m = stripped.match(/^==\s*([^=]+?)\s*==\s*$/))
      region = clean_wiki_label(m[1])
      province = nil
      next
    end

    if (m = stripped.match(/^===\s*([^=]+?)\s*===\s*$/))
      province = clean_wiki_label(m[1])
      next
    end

    # Page source list item or pasted rendered bullet/list text.
    next unless stripped.start_with?("*") || stripped =~ /\((?:[^)]*\d{3,4}[^)]*|unknown dates|dates unknown)\)/i
    next unless stripped =~ /\((?:[^)]*\d{3,4}[^)]*|unknown dates|dates unknown)\)/i

    line_body = stripped.sub(/^\*+\s*/, "")
    link_match = line_body.match(/\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|([^\]]+))?\]\][^\(]*\(([^)]*(?:\d{3,4}|unknown dates|dates unknown)[^)]*)\)/i)

    page_title = nil
    label = nil
    dates = nil

    if link_match
      page_title = clean_wiki_label(link_match[1])
      label = clean_wiki_label(link_match[2] || link_match[1])
      dates = link_match[3]
    else
      plain = clean_wiki_label(line_body)
      plain.sub!(/\s+[-–—].*\z/, "")
      plain_match = plain.match(/(.+?)\s*\(([^)]*(?:\d{3,4}|unknown dates|dates unknown)[^)]*)\)/i)
      next unless plain_match

      label = plain_match[1].strip
      page_title = "#{strip_domain_suffix(label)} Domain"
      dates = plain_match[2]
    end

    english_name = strip_domain_suffix(label)
    page_title = "#{strip_domain_suffix(page_title)} Domain" if page_title && page_title !~ /Domain\z/i && page_title !~ /\(.+\)/
    date_info = parse_date_expression(dates, date_basis: date_basis)

    review = []
    review.concat(date_info[:notes])
    page_base = strip_domain_suffix(page_title.to_s)
    review << "link_label_differs_from_page" if !page_base.empty? && page_base.casecmp?(english_name) == false
    review << "no_english_page_link" if page_title.nil? || page_title.empty?

    entries << {
      english_name: english_name,
      english_page_title: page_title,
      raw_dates: dates.strip,
      selected_intervals: date_info[:selected],
      all_intervals: date_info[:all],
      region_en: region,
      province_en: province,
      review_statuses: review.uniq,
      source: "enwiki_list_of_han"
    }
  end
  entries
end

def parse_japanese_entries(source_text)
  text = unwrap_source(source_text)
  entries = []
  region = nil
  province = nil

  text.each_line do |line|
    raw_line = line.chomp.strip
    next if raw_line.empty?
    next if raw_line.start_with?("※")

    if (m = raw_line.match(/^==\s*([^=]+?地方)\s*==/))
      region = clean_wiki_label(m[1])
      province = nil
      next
    elsif raw_line =~ /地方\z/ && raw_line !~ /藩/
      region = clean_wiki_label(raw_line)
      province = nil
      next
    end

    if (m = raw_line.match(/^===\s*([^=]+?国)\s*===/))
      province = clean_wiki_label(m[1])
      next
    elsif raw_line =~ /国\z/ && raw_line !~ /藩|領|一覧|関連/
      province = clean_wiki_label(raw_line)
      next
    end

    line_body = raw_line.sub(/^\*+\s*/, "")
    next unless line_body =~ /藩|領/
    next if line_body =~ /藩名|支藩の記事|藩の一覧|各地に存在/

    links = line_body.scan(/\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|([^\]]+))?\]\]/)
    preferred_link = links.find { |title, label| [title, label].compact.any? { |x| x.include?("藩") } } || links.first
    ja_page_title = preferred_link && preferred_link[0]

    cleaned = clean_wiki_label(line_body)
    display = main_japanese_name(cleaned)
    display = extract_japanese_han_name(cleaned) if display.empty? || !display.include?("藩")
    next if display.nil? || display.empty?

    aliases = cleaned.scan(/[（(＜<]([^）)>＞]+)[）)>＞]/).flatten.join("; ")
    date_hint = cleaned[/[（(](\d{3,4})年\s*-\s*(\d{3,4})?年?\s*[）)]/, 0]

    entries << {
      display_name: display,
      aliases: aliases,
      ja_page_title: ja_page_title || display,
      region_ja: region,
      province_ja: province,
      raw_ja_line: cleaned,
      date_hint: date_hint
    }
  end
  entries.uniq { |e| [e[:display_name], e[:ja_page_title], e[:region_ja], e[:province_ja]] }
end

# ---------- overrides ----------

def load_overrides(path)
  return {} unless path

  overrides = {}
  CSV.foreach(path, col_sep: "\t", headers: true, encoding: "UTF-8") do |row|
    display = row["display_name"].to_s.strip
    next if display.empty?

    %w[english_page_title english_name].each do |key|
      k = row[key].to_s.strip
      overrides[k] = display unless k.empty?
    end
  end
  overrides
end

# ---------- build ----------

http = PoliteHttp.new(
  delay_seconds: options[:sleep_seconds],
  retries: options[:max_retries],
  user_agent: options[:user_agent],
  cache_dir: options[:cache_dir],
  verbose: options[:verbose]
)

warn "HTTP settings: delay=#{options[:sleep_seconds]}s retries=#{options[:max_retries]} cache=#{options[:cache_dir]} html_langlinks=#{options[:resolve_html_langlinks]}" if options[:verbose]
if options[:start_cooldown].to_f.positive?
  warn "Initial cooldown: sleeping #{format('%.1f', options[:start_cooldown])}s before first live request"
  sleep options[:start_cooldown].to_f
end

english_source = read_source(options[:english], fetch: options[:fetch_english], wiki: :en, title: options[:english_title], http: http)
unless english_source
  warn "No English source supplied. Use --fetch-english or --english PATH."
  exit 1
end

japanese_source = read_source(options[:japanese], fetch: options[:fetch_japanese], wiki: :ja, title: options[:japanese_title], http: http)
unless japanese_source
  warn "No Japanese source supplied. Use --fetch-japanese or --japanese PATH."
  exit 1
end

english_entries = parse_english_entries(english_source, date_basis: options[:date_basis])
japanese_entries = parse_japanese_entries(japanese_source)
overrides = load_overrides(options[:overrides])

ja_by_page_title = {}
japanese_entries.each { |e| ja_by_page_title[e[:ja_page_title]] ||= e[:display_name] }
japanese_entries.each { |e| ja_by_page_title[e[:display_name]] ||= e[:display_name] }

html_ja_titles = {}
html_japanese_names = {}

if options[:resolve_html_langlinks]
  titles = english_entries.map { |e| e[:english_page_title] }.compact.uniq
  titles = titles.first(options[:max_html_pages]) if options[:max_html_pages]
  titles.each_with_index do |title, i|
    begin
      html = http.get(wiki_page_url(:en, title), context: "fetch HTML en:#{title} (#{i + 1}/#{titles.length})")
      ja_title = ja_title_from_html_alternate(html)
      html_ja_titles[title] = ja_title if ja_title
      name = extract_japanese_han_name(html_text_loose(html))
      html_japanese_names[title] = name if name
    rescue StandardError => e
      if e.respond_to?(:code) && [404, 410].include?(e.code.to_i)
        warn "Skipping missing optional HTML enrichment page for #{title}: HTTP #{e.code}" if options[:verbose]
      else
        warn "Could not fetch/parse HTML for #{title}: #{e.message.lines.first&.strip}"
      end
    end
  end
end

rows = []
english_entries.each do |entry|
  statuses = entry[:review_statuses].dup
  name_source = nil
  ja_page_title = nil
  display_name = nil

  if overrides[entry[:english_page_title]] || overrides[entry[:english_name]]
    display_name = overrides[entry[:english_page_title]] || overrides[entry[:english_name]]
    name_source = "manual_override"
  end

  if display_name.nil? && html_ja_titles[entry[:english_page_title]]
    ja_page_title = html_ja_titles[entry[:english_page_title]]
    display_name = ja_by_page_title[ja_page_title] || extract_japanese_han_name(ja_page_title) || ja_page_title
    name_source = "html_alternate_ja"
  end

  if display_name.nil? && html_japanese_names[entry[:english_page_title]]
    display_name = html_japanese_names[entry[:english_page_title]]
    name_source = "html_text_extract"
  end

  unless display_name && japanese_text?(display_name)
    statuses << "missing_japanese_name"
    display_name = nil
  end

  selected = entry[:selected_intervals]
  selected = [[nil, nil]] if selected.empty?

  selected.each_with_index do |(start_year, end_year), index|
    periods = start_year && end_year ? periods_for([start_year, end_year]) : []
    row_statuses = statuses.dup
    row_statuses << "multiple_intervals" if selected.length > 1
    row_statuses << "no_period_overlap" if start_year && end_year && periods.empty?

    next if display_name.nil? && !options[:include_missing_names]

    rows << {
      polity_id: "japan.#{slugify_id(entry[:english_name])}",
      display_name: display_name,
      start_year: start_year,
      end_year: end_year,
      type: options[:type],
      periods: periods.join(";"),
      english_name: entry[:english_name],
      english_page_title: entry[:english_page_title],
      ja_page_title: ja_page_title,
      ja_name_source: name_source,
      raw_dates: entry[:raw_dates],
      interval_index: selected.length > 1 ? index + 1 : nil,
      date_basis: options[:date_basis],
      region_en: entry[:region_en],
      province_en: entry[:province_en],
      review_status: row_statuses.empty? ? "ok" : row_statuses.uniq.join(";"),
      notes: "Dates from English List of han; Japanese names resolved from manual overrides or non-API English page HTML."
    }
  end
end

headers = %i[
  polity_id display_name start_year end_year type periods english_name english_page_title
  ja_page_title ja_name_source raw_dates interval_index date_basis region_en province_en review_status notes
]

CSV.open(options[:output], "w", col_sep: "\t", write_headers: true, headers: headers, encoding: "UTF-8") do |csv|
  rows.each { |row| csv << headers.map { |h| row[h] } }
end

review_rows = rows.reject { |row| row[:review_status] == "ok" }
CSV.open(options[:review_output], "w", col_sep: "\t", write_headers: true, headers: headers, encoding: "UTF-8") do |csv|
  review_rows.each { |row| csv << headers.map { |h| row[h] } }
end

ja_headers = %i[display_name ja_page_title aliases region_ja province_ja date_hint raw_ja_line]
CSV.open(options[:japanese_names_output], "w", col_sep: "\t", write_headers: true, headers: ja_headers, encoding: "UTF-8") do |csv|
  japanese_entries.each { |row| csv << ja_headers.map { |h| row[h] } }
end

counts_by_status = rows.each_with_object(Hash.new(0)) { |row, h| row[:review_status].split(";").each { |s| h[s] += 1 } }
counts_by_source = rows.each_with_object(Hash.new(0)) { |row, h| h[row[:ja_name_source] || "none"] += 1 }

puts "English entries parsed: #{english_entries.length}"
puts "Japanese entries parsed: #{japanese_entries.length}"
puts "Manifest rows written: #{rows.length} -> #{options[:output]}"
puts "Review rows written: #{review_rows.length} -> #{options[:review_output]}"
puts "Japanese names written: #{japanese_entries.length} -> #{options[:japanese_names_output]}"
puts "Name sources: #{counts_by_source.sort.map { |k, v| "#{k}=#{v}" }.join(', ')}"
puts "Review flags: #{counts_by_status.sort.map { |k, v| "#{k}=#{v}" }.join(', ')}"
