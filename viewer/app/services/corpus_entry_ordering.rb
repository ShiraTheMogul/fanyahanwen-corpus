# frozen_string_literal: true

class CorpusEntryOrdering
  BASE_MODES = %w[
    pc
    pronunciation
    cangjie
    wubi
    four_corner
    kangxi
    stroke_count
    yes
    frequency
  ].freeze

  # Folder periods are ranked by approximate start date. Exact dates are not
  # displayed to users; they only give unlike naming traditions a shared sort
  # axis. Unknown folders stay after known periods and keep PC/Unicode order.
  PERIOD_START = {
    # China
    "商殷朝" => -1600,
    "商朝" => -1600,
    "殷朝" => -1600,
    "周朝" => -1046,
    "西周" => -1046,
    "東周" => -770,
    "春秋時代" => -770,
    "戰國時代" => -475,
    "秦朝" => -221,
    "漢朝" => -206,
    "十八國" => -206.5,
    "西漢" => -206,
    "長沙國" => -202,
    "新朝" => 9,
    "東漢" => 25,
    "三國" => 220,
    "曹魏" => 220,
    "蜀漢" => 221,
    "東吳" => 222,
    "晉朝" => 266,
    "西晉" => 266,
    "十六國" => 304,
    "東晉" => 317,
    "漢趙" => 304,
    "成漢" => 304,
    "後趙" => 319,
    "前涼" => 301,
    "前燕" => 337,
    "苻秦" => 351,
    "後燕" => 384,
    "後秦" => 384,
    "西秦" => 385,
    "後涼" => 386,
    "南涼" => 397,
    "北涼" => 397,
    "南燕" => 398,
    "西涼" => 400,
    "夏" => 407,
    "北燕" => 407,
    "南北朝" => 420,
    "北魏" => 386,
    "劉宋" => 420,
    "南齊" => 479,
    "南梁" => 502,
    "東魏" => 534,
    "西魏" => 535,
    "北齊" => 550,
    "西梁" => 555,
    "北周" => 557,
    "南陳" => 557,
    "隋朝" => 581,
    "唐朝" => 618,
    "五代十國" => 907,
    "五代" => 907,
    "十國" => 902,
    "後梁" => 907,
    "後唐" => 923,
    "後晉" => 936,
    "後漢" => 947,
    "後周" => 951,
    "楊吳" => 902,
    "大蜀" => 907,
    "吳越" => 907,
    "馬楚" => 907,
    "閩" => 909,
    "南漢" => 917,
    "荆南" => 924,
    "後蜀" => 934,
    "南唐" => 937,
    "北漢" => 951,
    "宋朝" => 960,
    "遼朝" => 916,
    "北宋" => 960,
    "西夏" => 1038,
    "金朝" => 1115,
    "南宋" => 1127,
    "元朝" => 1271,
    "明朝" => 1368,
    "清朝" => 1644,
    "中華民國" => 1912,
    "中華帝國" => 1915,
    "中華人民共和國" => 1949,

    # Japan
    "倭" => 250,
    "弥生時代" => -300,
    "古墳時代" => 250,
    "飛鳥時代" => 592,
    "日本" => 701,
    "奈良時代" => 710,
    "平安時代" => 794,
    "鎌倉時代" => 1185,
    "南北朝時代" => 1336,
    "室町時代" => 1337,
    "安土桃山時代" => 1568,
    "江戸時代" => 1603,
    "大日本帝国" => 1868,
    "明治時代" => 1868,
    "大正時代" => 1912,
    "昭和時代" => 1926,
    "平成時代" => 1989,
    "令和時代" => 2019,

    # Korea
    "古朝鮮" => -700,
    "三韓" => -100,
    "原三國" => -100,
    "耽羅" => 1,
    "加倻" => 42,
    "渤海" => 698,
    "後三國" => 892,
    "高麗" => 918,
    "朝鮮王朝" => 1392,
    "大韓國" => 1897,

    # Vietnam
    "北屬及間歇獨立時期" => -111,
    "南越" => -204,
    "第一次北屬" => -111,
    "第二次北屬" => 43,
    "前李朝" => 544,
    "第三次北屬" => 602,
    "吳朝" => 939,
    "丁朝" => 968,
    "李朝" => 1009,
    "大越" => 1054,
    "陳朝" => 1225,
    "第四次北屬" => 1407,
    "後黎朝" => 1428,
    "莫朝" => 1527,
    "黎中興朝" => 1533,
    "西山朝" => 1778,
    "阮朝" => 1802,
    "越南民主共和國" => 1945,
    "越南共和國" => 1955,
    "越南社會主義共和國" => 1976,

    # Ryukyu
    "三山時代" => 1314,
    "三山" => 1314,
    "琉球國" => 1429,
    "第一尚氏王朝" => 1429,
    "第二尚氏王朝" => 1470,

    # Singapore / modern regional collections
    "海峽殖民地" => 1826,
    "昭南島" => 1942,
    "新加坡" => 1965
  }.freeze

  # Some labels are ambiguous outside their historical collection. These
  # context-specific values take precedence over the general table above.
  REGIONAL_PERIOD_START = {
    "中國漢文/clean/五代十國" => {
      "岐" => 901,
      "十國" => 902,
      "楊吳" => 902,
      "五代" => 907,
      "後梁" => 907,
      "大蜀" => 907,
      "吳越" => 907,
      "馬楚" => 907,
      "閩" => 909,
      "趙" => 910,
      "燕" => 911,
      "南漢" => 917,
      "後唐" => 923,
      "荆南" => 924,
      "後蜀" => 934,
      "後晉" => 936,
      "南唐" => 937,
      "大理國" => 937,
      "大殷" => 943,
      "後漢" => 947,
      "後周" => 951,
      "北漢" => 951
    },
    "朝鮮漢文" => {
      "古朝鮮" => -700,
      "三韓" => -100,
      "原三國" => -100,
      "三國" => -57,
      "新羅" => -57,
      "高句麗" => -37,
      "百濟" => -18,
      "耽羅" => 1,
      "加倻" => 42,
      "渤海" => 698,
      "後三國" => 892,
      "高麗" => 918,
      "朝鮮王朝" => 1392,
      "大韓國" => 1897,
      "大韓民國" => 1948.08,
      "朝鮮民主主義人民共和國" => 1948.09
    }
  }.freeze

  UNKNOWN_PERIOD_RANK = 10_000
  QIANZIWEN_PATH = Rails.root.join("data", "qianziwen_order.txt")
  YES_ORDER_PATH = Rails.root.join("data", "yes_order_unified_ideographs.txt")

  attr_reader :effective_mode

  def initialize(requested_mode: nil, qianziwen_first: false, pronunciation_source: nil, context_path: nil)
    @requested_mode = requested_mode.to_s.presence
    @qianziwen_first = truthy?(qianziwen_first)
    @pronunciation_source_key = pronunciation_source.to_s.presence || "mandarin"
    @context_path = context_path.to_s.tr("\\", "/")
    @period_available = false
    @effective_mode = nil
    @prepared_names = nil
    @codepoint_id_by_codepoint = {}
    @values = {}
    @qianziwen_rank = self.class.qianziwen_rank
  end

  # CorpusFs calls prepare once with the complete set it is about to sort.
  # That lets us bulk-load all needed character data in a handful of queries.
  # There is no per-file metadata lookup and no N+1 database loop.
  def prepare(names)
    names = Array(names)
    signature = names.hash
    return self if @prepared_names == signature

    @prepared_names = signature
    @period_available = names.count { |name| period_rank(name) < UNKNOWN_PERIOD_RANK } >= 2
    @effective_mode = resolve_mode

    load_character_data(names) unless %w[period pc yes].include?(@effective_mode)
    self
  end

  def key(name)
    prepare([name]) if @effective_mode.nil?

    base = sortable_name(name)
    if @effective_mode == "period"
      [period_rank(base), base]
    else
      [base.each_char.map { |char| decorated_character_key(char) }, base]
    end
  end

  def period_available?
    @period_available
  end

  def qianziwen_first?
    @qianziwen_first
  end

  def qianziwen_applied?
    @qianziwen_first && @effective_mode != "period"
  end

  def yes_available?
    self.class.yes_order_rank.any?
  rescue Errno::ENOENT, EncodingError
    false
  end

  def pronunciation_label
    source = PronunciationRegistry.ruby_source(@pronunciation_source_key)
    return "Selected pronunciation" unless source

    PronunciationRegistry.display_ruby_source_label(source).presence || "Selected pronunciation"
  rescue StandardError
    "Selected pronunciation"
  end

  private

  def resolve_mode
    if @requested_mode == "period"
      return @period_available ? "period" : "pc"
    end

    if BASE_MODES.include?(@requested_mode)
      return "pc" if @requested_mode == "yes" && !yes_available?
      return @requested_mode
    end

    @period_available ? "period" : "pc"
  end

  def sortable_name(name)
    File.basename(name.to_s, File.extname(name.to_s))
  end

  def period_rank(name)
    label = sortable_name(name)
    regional = REGIONAL_PERIOD_START.find { |prefix, _values| @context_path.include?(prefix) }&.last
    return regional[label] if regional&.key?(label)

    PERIOD_START.fetch(label, UNKNOWN_PERIOD_RANK)
  end

  def decorated_character_key(char)
    base = character_key(char)
    return base unless qianziwen_applied?

    rank = @qianziwen_rank[char]
    rank ? [0, rank] : [1, base]
  end

  def character_key(char)
    cp = char.ord

    if @effective_mode == "yes"
      rank = self.class.yes_order_rank[char]
      # The published list covers essentially all Basic CJK Unified Ideographs
      # plus several hundred additional characters. Characters outside the
      # snapshot keep a deterministic PC/Unicode fallback after ranked items.
      return rank ? [0, rank, cp] : [1, cp]
    end

    unless CharacterData::HanCharacter.codepoint?(cp)
      # PC order is codepoint order. In every other character mode, keep
      # non-Han text in its own numeric bucket so Ruby never has to compare a
      # String lookup value (for a Han character) with an Integer codepoint.
      return [0, cp] if @effective_mode == "pc"

      return [2, cp]
    end

    case @effective_mode
    when "pronunciation"
      string_key(cp)
    when "cangjie", "wubi", "four_corner"
      string_key(cp)
    when "kangxi"
      radical_key(cp)
    when "stroke_count"
      numeric_key(cp)
    when "frequency"
      frequency_key(cp)
    else
      [0, cp]
    end
  end

  def string_key(codepoint)
    value = @values[codepoint]
    return [1, "", codepoint] if value.blank?

    normalized = value.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase
    [0, normalized, value.to_s, codepoint]
  end

  def numeric_key(codepoint)
    value = @values[codepoint]
    number = value.to_s[/\d+/, 0]&.to_i
    number ? [0, number, codepoint] : [1, 0, codepoint]
  end

  def radical_key(codepoint)
    value = @values[codepoint].to_s.split(/\s+/).first.to_s
    match = value.match(/\A(?<radical>\d+)(?<variant>')?\.(?<extra>\d+)/)
    return [1, 999, 1, 999, codepoint] unless match

    [
      0,
      match[:radical].to_i,
      match[:variant].present? ? 1 : 0,
      match[:extra].to_i,
      codepoint
    ]
  end

  def frequency_key(codepoint)
    value = @values[codepoint].to_s
    counts = value.scan(/\((\d+)\)/).flatten.map!(&:to_i)
    return [1, 0, codepoint] if counts.empty?

    [0, -counts.sum, codepoint]
  end

  def load_character_data(names)
    codepoints = names
      .flat_map { |name| CharacterData::HanCharacter.codepoints(sortable_name(name)) }
      .uniq
    return if codepoints.empty?

    rows = CharacterCodepoint.where(codepoint: codepoints).pluck(:id, :codepoint)
    @codepoint_id_by_codepoint = rows.to_h { |id, cp| [cp, id] }
    id_to_codepoint = rows.to_h
    ids = @codepoint_id_by_codepoint.values
    return if ids.empty?

    @values =
      case @effective_mode
      when "pronunciation"
        load_pronunciation(ids)
      when "cangjie"
        load_input_codes(ids, "cangjie5").merge(load_properties(ids, "kCangjie")) { |_id, input, _unihan| input }
      when "wubi"
        load_input_codes(ids, "wubi86")
      when "four_corner"
        load_properties(ids, "kFourCornerCode")
      when "kangxi"
        load_properties(ids, "kRSUnicode")
      when "stroke_count"
        load_properties(ids, "kTotalStrokes")
      when "frequency"
        load_properties(ids, "kHanyuPinlu")
      else
        {}
      end

    @values = @values.each_with_object({}) do |(id, value), memo|
      cp = id_to_codepoint[id]
      memo[cp] = value if cp
    end
  end

  def load_pronunciation(ids)
    source = PronunciationRegistry.ruby_source(@pronunciation_source_key)
    return {} unless source

    field = source[:field].to_s
    allowed_sources = Array(source[:sources]).map(&:to_s)
    rows = CharacterProperty.where(character_codepoint_id: ids, field: field).pluck(
      :character_codepoint_id, :source, :value
    )
    source_order = allowed_sources.each_with_index.to_h

    rows.group_by(&:first).transform_values do |group|
      group.min_by do |_id, row_source, value|
        [
          source_order.fetch(row_source.to_s, allowed_sources.empty? ? 0 : 9_999),
          normalized_string(value)
        ]
      end.last
    end
  rescue ActiveRecord::StatementInvalid
    {}
  end

  def load_properties(ids, field)
    rows = CharacterProperty.where(character_codepoint_id: ids, field: field).pluck(
      :character_codepoint_id, :source, :value
    )

    rows.group_by(&:first).transform_values do |group|
      group.min_by { |_id, source, value| [source.to_s, normalized_string(value)] }.last
    end
  rescue ActiveRecord::StatementInvalid
    {}
  end

  def load_input_codes(ids, system_id)
    return {} unless defined?(CharacterInputCode) && CharacterInputCode.table_exists?

    rows = CharacterInputCode.where(
      character_codepoint_id: ids,
      system_id: system_id
    ).pluck(:character_codepoint_id, :code)

    rows.group_by(&:first).transform_values do |group|
      group.map(&:last).min_by { |value| normalized_string(value) }
    end
  rescue ActiveRecord::StatementInvalid
    {}
  end

  def normalized_string(value)
    value.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").downcase
  end

  def truthy?(value)
    %w[1 true yes on].include?(value.to_s.downcase)
  end

  class << self
    def yes_order_rank
      @yes_order_rank ||= begin
        raw = File.binread(YES_ORDER_PATH).force_encoding(Encoding::UTF_8)
        raw = raw.scrub.delete_prefix("\uFEFF")
        body = raw.each_line.reject { |line| line.lstrip.start_with?("#") }.join
        chars = body.each_char.reject { |char| char.match?(/\s/) }

        # Preserve the source snapshot exactly while giving duplicate entries a
        # single stable rank: the first published occurrence wins.
        rank = {}
        chars.each_with_index { |char, index| rank[char] ||= index }

        unless rank.length >= 20_000 && rank["一"] == 0 && rank["二"] == 1 && rank["三"] == 2
          raise "yes_order_unified_ideographs.txt does not look like a valid YES-order snapshot"
        end

        rank.freeze
      end
    end

    def qianziwen_rank
      @qianziwen_rank ||= begin
        raw = File.binread(QIANZIWEN_PATH).force_encoding(Encoding::UTF_8)
        raw = raw.scrub.delete_prefix("\uFEFF")
        body = raw.each_line.reject { |line| line.lstrip.start_with?("#") }.join
        chars = CharacterData::HanCharacter.each_char(body).to_a

        unless chars.length == 1_000 && chars.uniq.length == 1_000
          raise "qianziwen_order.txt must contain exactly 1,000 distinct Han characters"
        end

        chars.each_with_index.to_h { |char, index| [char, index] }.freeze
      end
    end
  end
end
