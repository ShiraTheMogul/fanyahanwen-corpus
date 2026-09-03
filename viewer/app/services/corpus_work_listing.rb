# frozen_string_literal: true

require "pathname"

# Lightweight catalogue for one corpus work folder.
#
# A work with several documents opens as a chapter/document index. This avoids
# reading every source file and expanding an entire book into indexed reader
# HTML merely because the user opened the work folder.
#
# Older migrated metadata sometimes records documents in lexicographic order
# (卷一, 卷十, 卷二). Ordering here is deliberately conservative: clear front
# matter is promoted, clear appendices/postscripts are placed after the main
# text, and only recognised numbered series that are demonstrably out of order
# are sorted. Unknown labels keep their declared metadata order.
class CorpusWorkListing
  Document = Struct.new(:path, :label, keyword_init: true)
  Page = Struct.new(:documents, :page, :per_page, :total, :total_pages, keyword_init: true) do
    def paths
      documents.map(&:path)
    end
  end

  HAN_NUMBER_CHARS = "〇零○一二兩两三四五六七八九十百千萬万廿卄卅卌壹貳贰參叁肆伍陸陆柒捌玖拾佰仟元".freeze
  NUMBER_TOKEN_SOURCE = "(?:\\d+|[#{Regexp.escape(HAN_NUMBER_CHARS)}]+)".freeze
  STRUCTURAL_UNIT_SOURCE = "(?:卷|篇|章|回|節|节|部|冊|册|集|公約|公约)".freeze

  UNIT_BEFORE_NUMBER_RE = Regexp.new(
    "\\A(?<prefix>.*?)(?<unit>#{STRUCTURAL_UNIT_SOURCE})(?:之)?(?:第)?(?<number>#{NUMBER_TOKEN_SOURCE}|上|中|下)(?<suffix>.*)\\z"
  ).freeze
  NUMBER_BEFORE_UNIT_RE = Regexp.new(
    "\\A(?<prefix>.*?)(?:第)?(?<number>#{NUMBER_TOKEN_SOURCE}|上|中|下)(?<unit>#{STRUCTURAL_UNIT_SOURCE})(?<suffix>.*)\\z"
  ).freeze
  NUMBERED_TITLE_RE = Regexp.new(
    "\\A(?<prefix>.*?)第(?<number>#{NUMBER_TOKEN_SOURCE})(?<suffix>[^0-9#{Regexp.escape(HAN_NUMBER_CHARS)}]*)\\z"
  ).freeze
  HAN_TRAILING_NUMBER_RE = Regexp.new(
    "\\A(?<prefix>.+?)(?<number>[#{Regexp.escape(HAN_NUMBER_CHARS)}]+)\\z"
  ).freeze

  FRONT_MATTER_RE = Regexp.new(
    "\\A(?:序|敘|叙|自序|自敘|自叙|前言|引言|凡例|例言|題辭|题辞|題詞|题词|序說|序説|敘篇|叙篇|首卷|卷首|目錄|目录|目録|總目|总目|目次|提要)(?:#{NUMBER_TOKEN_SOURCE})?\\z"
  ).freeze
  FRONT_MATTER_SUFFIX_RE = Regexp.new(
    "(?:序|敘|叙|例言|凡例|前言|引言|緒言|绪言|弁言|小引|題辭|题辞|題詞|题词)(?:#{NUMBER_TOKEN_SOURCE})?\\z"
  ).freeze
  POST_MATTER_RE = Regexp.new(
    "(?:跋|跋文|跋語|跋语|後序|后序|後記|后记|書後|书后|後跋|后跋)(?:#{NUMBER_TOKEN_SOURCE})?\\z"
  ).freeze
  APPENDIX_RE = /\A(?:附錄|附录|附録|補遺|补遗|拾遺|拾遗|附言|附記|附记|校勘記|校勘记)/.freeze

  # If a family repeats a large fraction of its ordinals, it may contain two
  # witnesses or several pages per chapter. Sorting such a family could mix the
  # witnesses together, so leave it alone. A single accidental duplicate in a
  # long sequence (for example two records labelled 第十七) is still sortable.
  MAX_DUPLICATE_ORDINAL_RATIO = 0.15
  MIN_HAN_TRAILING_FAMILY_SIZE = 3

  HAN_DIGITS = {
    "〇" => 0, "零" => 0, "○" => 0,
    "一" => 1, "壹" => 1,
    "二" => 2, "兩" => 2, "两" => 2, "貳" => 2, "贰" => 2,
    "三" => 3, "參" => 3, "叁" => 3,
    "四" => 4, "肆" => 4,
    "五" => 5, "伍" => 5,
    "六" => 6, "陸" => 6, "陆" => 6,
    "七" => 7, "柒" => 7,
    "八" => 8, "捌" => 8,
    "九" => 9, "玖" => 9,
    "元" => 1
  }.freeze
  HAN_SMALL_UNITS = {
    "十" => 10, "拾" => 10,
    "百" => 100, "佰" => 100,
    "千" => 1_000, "仟" => 1_000
  }.freeze
  HAN_LARGE_UNITS = { "萬" => 10_000, "万" => 10_000 }.freeze
  PART_ORDINALS = { "上" => 1, "中" => 2, "下" => 3 }.freeze

  def initialize(root:, fs:, metadata_store:, rel_path:)
    @root = Pathname(File.realpath(root.to_s))
    @fs = fs
    @metadata_store = metadata_store
    @rel_path = normalize_rel(rel_path)
    @abs_path = Pathname(@fs.resolve(@rel_path))
  end

  def work_folder?
    own_metadata? && document_count.positive?
  end

  def document_count
    document_entries.length
  end

  # Multi-document works always open at the index. Only a one-document work may
  # enter the reader directly, and the existing byte budget still protects that
  # one source file.
  def inline_renderable?(document_limit:, byte_limit:)
    return false unless document_count == 1
    return false if document_limit.to_i < 1

    budget = [byte_limit.to_i, 0].max
    return false if budget.zero?

    absolute = @fs.resolve(document_entries.first[:path])
    File.size(absolute) <= budget
  rescue Errno::ENOENT, Errno::EACCES, SecurityError
    false
  end

  def page(page:, per_page:)
    page = [page.to_i, 1].max
    per_page = [[per_page.to_i, 1].max, 500].min
    entries = document_entries
    total = entries.length
    total_pages = [(total.to_f / per_page).ceil, 1].max
    page = [page, total_pages].min
    slice = entries.slice((page - 1) * per_page, per_page) || []

    Page.new(
      documents: slice.map { |entry| Document.new(path: entry[:path], label: entry[:display_label]) },
      page: page,
      per_page: per_page,
      total: total,
      total_pages: total_pages
    )
  end

  private

  def own_metadata?
    relative = @metadata_store.metadata_relative_path_for(@rel_path).to_s.tr("\\", "/")
    return false if relative.empty?

    metadata_dir = File.dirname(relative)
    metadata_dir = "" if metadata_dir == "."
    metadata_dir == @rel_path
  end

  def document_entries
    @document_entries ||= begin
      metadata = @metadata_store.metadata_for_path(@rel_path)
      entries = @metadata_store.document_hashes_for(metadata).each_with_index.filter_map do |document, index|
        next unless document.is_a?(Hash)

        path = document_path(document)
        next if path.empty?

        labels = metadata_document_labels(document, metadata, path)
        {
          path: path,
          index: index,
          order_label: labels[:order_label],
          display_label: labels[:display_label],
          series: labels[:series]
        }
      end

      entries = deduplicate_entries(entries)
      entries = fallback_text_entries if entries.empty?
      order_document_entries(entries)
    end
  end

  def document_path(document)
    explicit = normalize_rel(document["path"])
    return explicit unless explicit.empty?

    file = document["file"].to_s.strip
    return "" if file.empty?

    [@rel_path, file].reject(&:empty?).join("/")
  end

  def fallback_text_entries
    return [] unless @abs_path.directory?

    Dir.children(@abs_path)
      .select { |name| name.downcase.end_with?(".txt") }
      .sort
      .each_with_index
      .map do |raw_name, index|
        name = utf8_string(raw_name)
        label = filename_label(name)
        {
          path: [@rel_path, name].reject(&:empty?).join("/"),
          index: index,
          order_label: label,
          display_label: label,
          series: ""
        }
      end
  end

  def deduplicate_entries(entries)
    seen = {}
    entries.select do |entry|
      next false if seen[entry[:path]]

      seen[entry[:path]] = true
    end
  end

  # page_title carries useful hierarchy. For example:
  #   大上海都市計劃/三稿/第一章
  # The reader should display "三稿 / 第一章" and sort 第一章 only inside 三稿.
  # Keeping that hierarchy avoids mixing repeated chapter sequences belonging to
  # different parts or editions of the same work.
  def metadata_document_labels(document, metadata, path)
    work_title = first_present(metadata["title"], metadata["work_base_title"], metadata["work_title"])
    page_title = document["page_title"].to_s.strip

    unless page_title.empty?
      parts = page_title.tr("\\", "/").split("/").map(&:strip).reject(&:empty?)
      if parts.length > 1 && same_label?(parts.first, work_title)
        parts = parts.drop(1)
      end

      unless parts.empty?
        return {
          order_label: parts.last,
          display_label: parts.join(" / "),
          series: parts[0...-1].join("/")
        }
      end
    end

    %w[chapter display_title title].each do |key|
      value = document[key].to_s.strip
      next if value.empty?
      next if same_label?(value, work_title)

      return { order_label: value, display_label: value, series: "" }
    end

    label = filename_label(path)
    { order_label: label, display_label: label, series: "" }
  end

  def first_present(*values)
    values.find { |value| !value.to_s.strip.empty? }.to_s
  end

  def same_label?(left, right)
    return false if right.to_s.strip.empty?

    normalized_label(left) == normalized_label(right)
  end

  def filename_label(value)
    base = File.basename(utf8_string(value).tr("\\", "/"))
    extension = File.extname(base)
    extension.empty? ? base : base.delete_suffix(extension)
  end

  def order_document_entries(entries)
    classified = entries.map do |entry|
      ordinal = structural_ordinal(entry[:order_label], entry[:series])
      entry.merge(
        role: document_role(entry[:order_label], ordinal),
        ordinal_info: ordinal
      )
    end

    %i[front main appendix post].flat_map do |role|
      order_role_entries(classified.select { |entry| entry[:role] == role })
    end
  end

  # A sortable family becomes one block at the position of its first member.
  # This repairs lexicographic migrations such as 導言七 ... 導言一 while
  # preserving already-correct interleaving such as 卷一, 續卷一, 卷二, 續卷二.
  def order_role_entries(entries)
    families = entries.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |entry, memo|
      info = entry[:ordinal_info]
      memo[info[:family]] << entry if info
    end

    sorted_families = families.each_with_object({}) do |(family, members), memo|
      next unless family_should_sort?(members)

      memo[family] = members.sort_by { |entry| [entry[:ordinal_info][:ordinal], entry[:index]] }
    end

    emitted = {}
    entries.each_with_object([]) do |entry, ordered|
      info = entry[:ordinal_info]
      family = info && info[:family]

      if family && sorted_families.key?(family)
        next if emitted[family]

        ordered.concat(sorted_families.fetch(family))
        emitted[family] = true
      else
        ordered << entry
      end
    end
  end

  def family_should_sort?(members)
    return false if members.length < 2

    infos = members.map { |entry| entry[:ordinal_info] }
    return false if infos.first[:kind] == :han_trailing && members.length < MIN_HAN_TRAILING_FAMILY_SIZE

    ordinals = infos.map { |info| info[:ordinal] }
    duplicate_ratio = (ordinals.length - ordinals.uniq.length).to_f / ordinals.length
    return false if duplicate_ratio > MAX_DUPLICATE_ORDINAL_RATIO
    return false if ordinals.each_cons(2).all? { |left, right| left <= right }

    true
  end

  # 附錄卷一 is an appendix even though it has a structural number. Other
  # numbered labels ending in 序/跋 are local to that volume/chapter and should
  # stay with the main sequence instead of moving to the work's front/back.
  def document_role(label, ordinal_info)
    value = normalized_label(label)
    return :appendix if appendix?(value)

    # Strong structural forms such as 卷一序 are local to that numbered unit.
    # The generic Han-suffix heuristic is weaker, so a label such as 序二 still
    # counts as whole-work front matter.
    return :main if ordinal_info && ordinal_info[:kind] != :han_trailing
    return :post if post_matter?(value)
    return :front if front_matter?(value)

    :main
  end

  def structural_ordinal(label, series)
    value = normalized_label(label)
    return nil if value.empty?

    if (match = UNIT_BEFORE_NUMBER_RE.match(value))
      return ordinal_hash(
        kind: :structural,
        series: series,
        prefix: match[:prefix],
        unit: match[:unit],
        number: match[:number]
      )
    end

    if (match = NUMBER_BEFORE_UNIT_RE.match(value))
      return ordinal_hash(
        kind: :structural,
        series: series,
        prefix: match[:prefix],
        unit: match[:unit],
        number: match[:number]
      )
    end

    if (match = NUMBERED_TITLE_RE.match(value))
      ordinal = parse_ordinal(match[:number])
      return nil unless ordinal

      return {
        kind: :numbered_title,
        family: family_key(series, "numbered-title", match[:suffix]),
        ordinal: ordinal
      }
    end

    # This deliberately accepts Han numerals only. Generic Arabic suffixes are
    # common catalogue/object identifiers in the archaeological corpus and must
    # not be mistaken for chapter numbers.
    if (match = HAN_TRAILING_NUMBER_RE.match(value))
      ordinal = parse_ordinal(match[:number])
      return nil unless ordinal

      return {
        kind: :han_trailing,
        family: family_key(series, "han-tail", match[:prefix]),
        ordinal: ordinal
      }
    end

    nil
  end

  def ordinal_hash(kind:, series:, prefix:, unit:, number:)
    ordinal = parse_ordinal(number)
    return nil unless ordinal

    {
      kind: kind,
      family: family_key(series, prefix, unit),
      ordinal: ordinal
    }
  end

  def family_key(*parts)
    parts.map { |part| normalized_label(part) }.join("\u001F")
  end

  def front_matter?(value)
    value.match?(FRONT_MATTER_RE) || value.match?(FRONT_MATTER_SUFFIX_RE)
  end

  def post_matter?(value)
    value.match?(POST_MATTER_RE)
  end

  def appendix?(value)
    value.match?(APPENDIX_RE)
  end

  def normalized_label(value)
    utf8_string(value).strip.gsub(/[[:space:]]+/, "")
  end

  def utf8_string(value)
    text = value.to_s.dup
    text.force_encoding(Encoding::UTF_8) if text.encoding == Encoding::ASCII_8BIT
    text
  end

  def parse_ordinal(token)
    return nil if token.to_s.empty?
    return token.to_i if token.match?(/\A\d+\z/)
    return PART_ORDINALS[token] if PART_ORDINALS.key?(token)

    chinese_number_value(token)
  end

  def chinese_number_value(token)
    value = token
      .gsub("廿", "二十")
      .gsub("卄", "二十")
      .gsub("卅", "三十")
      .gsub("卌", "四十")

    if value.chars.all? { |char| HAN_DIGITS.key?(char) }
      return value.chars.reduce(0) { |number, char| (number * 10) + HAN_DIGITS.fetch(char) }
    end

    total = 0
    section = 0
    number = 0

    value.each_char do |char|
      if HAN_DIGITS.key?(char)
        number = HAN_DIGITS.fetch(char)
      elsif HAN_SMALL_UNITS.key?(char)
        unit = HAN_SMALL_UNITS.fetch(char)
        number = 1 if number.zero?
        section += number * unit
        number = 0
      elsif HAN_LARGE_UNITS.key?(char)
        unit = HAN_LARGE_UNITS.fetch(char)
        section += number
        section = 1 if section.zero?
        total += section * unit
        section = 0
        number = 0
      else
        return nil
      end
    end

    total + section + number
  end

  def normalize_rel(value)
    utf8_string(value).tr("\\", "/").sub(%r{\A/+}, "").sub(%r{/+\z}, "")
  end
end
