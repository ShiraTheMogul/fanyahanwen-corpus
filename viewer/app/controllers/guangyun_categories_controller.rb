# frozen_string_literal: true

# Guangyun category browser (tone + rime).
#
# Category storage:
#   CharacterProperty(source="Guangyun (Siku)", field="guangyun_category", value="上平聲｜8.微")
#
# Routing gotcha:
#   Rails treats "." in a path segment as the format separator, so we use a dot-free
#   route key in URLs:
#     "上平聲｜8｜微"
#   and translate route_key -> DB category value in the controller.
class GuangyunCategoriesController < ApplicationController
  DEFAULT_PER = 50
  MAX_PER = 200
  DEFAULT_SOURCE = "Guangyun (Siku)"

  before_action :load_category, only: [:show, :chars]
  before_action :parse_category_parts!, only: [:show, :chars]
  before_action :load_pagination, only: [:show, :chars]

  def index
    scope = CharacterProperty.where(source: DEFAULT_SOURCE, field: "guangyun_category")
    categories = scope.select(:value).distinct.order(:value).pluck(:value)

    tone_order = ["上平聲", "下平聲", "上聲", "去聲", "入聲"]
    @tone_groups = tone_order.index_with { [] }

    categories.each do |cat|
      tone, rest = cat.to_s.split("｜", 2)
      tone = tone.to_s.strip
      next if tone.empty? || rest.to_s.strip.empty?

      num = nil
      rime = rest.to_s.strip
      if (m = rime.match(/\A(\d+)\.(.+)\z/))
        num = m[1].to_i
        rime = m[2].to_s.strip
      end

      route_key =
        if num
          "#{tone}｜#{num}｜#{rime}"
        else
          "#{tone}｜#{rime}".tr(".", "·")
        end

      entry = { category: cat, route_key: route_key, number: num, rhyme: rime }
      if @tone_groups.key?(tone)
        @tone_groups[tone] << entry
      else
        (@tone_groups["其他"] ||= []) << entry
      end
    end

    @tone_groups.each_value do |arr|
      arr.sort_by! { |e| [(e[:number] || 999_999), e[:rhyme].to_s] }
    end

    q = params[:q].to_s.strip
    @lookup = lookup_payload(q) if q.present?
  end

  def show
    base = CharacterProperty.where(source: DEFAULT_SOURCE, field: "guangyun_category", value: @category_value)
    @total = base.select(:character_codepoint_id).distinct.count
    @category_rows_exist = base.exists?

    # For the left "Example readings" box, use the rime head character itself if possible.
    @example_char = nil
    if @rime_char.present?
      @example_char = CharacterCodepoint.find_by(chr: @rime_char)
    end

    # Fallback: first member character in this category
    if @example_char.nil?
      first_id = base.select(:character_codepoint_id).distinct.order(:character_codepoint_id).limit(1).pluck(:character_codepoint_id).first
      @example_char = first_id ? CharacterCodepoint.find_by(id: first_id) : nil
    end

    if @example_char
      ex = fetch_fields(@example_char.id, %w[bs2014_mc kTang kMandarin kJapaneseOn kKorean kVietnamese])
      @example_bs2014 = ex["bs2014_mc"]
      @example_ktang  = ex["kTang"]
      @example_man    = ex["kMandarin"]
      @example_jpn    = ex["kJapaneseOn"]
      @example_kor    = ex["kKorean"]
      @example_vie    = ex["kVietnamese"]
    end
  end

  def chars
    base = CharacterProperty.where(source: DEFAULT_SOURCE, field: "guangyun_category", value: @category_value)
    @total = base.select(:character_codepoint_id).distinct.count

    @characters = CharacterCodepoint
      .joins(:character_properties)
      .where(character_properties: { source: DEFAULT_SOURCE, field: "guangyun_category", value: @category_value })
      .distinct
      .order(:codepoint)
      .limit(@per)
      .offset((@page - 1) * @per)
      .to_a

    ids = @characters.map(&:id)

    # Always initialise to hashes so the table partial never crashes.
    @pairs_by_id   = {}
    @bs2014_mc     = Hash.new { |h, k| h[k] = [] }
    @k_tang        = Hash.new { |h, k| h[k] = [] }
    @k_mandarin    = Hash.new { |h, k| h[k] = [] }
    @k_japanese    = Hash.new { |h, k| h[k] = [] }
    @k_korean      = Hash.new { |h, k| h[k] = [] }
    @k_vietnamese  = Hash.new { |h, k| h[k] = [] }
    @unihan_defs   = Hash.new { |h, k| h[k] = [] }

    @def_source = (params[:def].presence || "guangyun").to_s

    if ids.any?
      @pairs_by_id = build_pairs_from_payload_raw(ids)

      readings = CharacterProperty
        .where(character_codepoint_id: ids, field: %w[bs2014_mc kTang kMandarin kJapaneseOn kKorean kVietnamese kDefinition])
        .order(:id)
        .pluck(:character_codepoint_id, :field, :value)

      readings.each do |ccid, field, value|
        v = value.to_s.strip
        next if v.empty?
        case field
        when "bs2014_mc"    then @bs2014_mc[ccid] << v
        when "kTang"        then @k_tang[ccid] << v
        when "kMandarin"    then @k_mandarin[ccid] << v
        when "kJapaneseOn"  then @k_japanese[ccid] << v
        when "kKorean"      then @k_korean[ccid] << v
        when "kVietnamese"  then @k_vietnamese[ccid] << v
        when "kDefinition"  then @unihan_defs[ccid] << v
        end
      end
    end

    render layout: false
  end

  private

  # Translate params[:category] into:
  # - @category_value (DB value containing dot form)
  # - @route_key      (dot-free form used in URLs)
  # - @category       (display string used by the view)
  def load_category
    raw = params[:category].to_s.strip
    raise ActiveRecord::RecordNotFound if raw.blank?

    if raw.include?("｜")
      parts = raw.split("｜")
      if parts.length == 3 && parts[1].match?(/\A\d+\z/)
        tone = parts[0].to_s.strip
        num  = parts[1].to_i
        rime = parts[2].to_s.strip
        @category_value = "#{tone}｜#{num}.#{rime}"
        @route_key = raw
      else
        @category_value = raw.tr("·", ".")
        @route_key = raw.tr(".", "·")
      end
    else
      @category_value = raw
      @route_key = raw.tr(".", "·")
    end

    # Default display uses the DB value, but we may later rewrite it in parse_category_parts!
    @category = @category_value
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

  # Keep both spellings around: earlier iterations used rhyme_*, current view expects rime_*.
  def parse_category_parts!
    @tone = nil
    @rhyme_number = nil
    @rhyme_name = nil
    @rime_number = nil
    @rime_name = nil
    @rime_char = nil

    cat = @category_value.to_s
    return if cat.blank?

    tone_part, rest = cat.split("｜", 2)
    @tone = tone_part.to_s.strip.presence

    num = nil
    name = nil

    if rest.present?
      if (m = rest.match(/\A(\d+)\.(.+)\z/))
        num = m[1].to_i
        name = m[2].to_s.strip
      else
        name = rest.to_s.strip
      end
    end

    # Clip non-Han characters from the rime name for display + for head character lookup.
    han = name.to_s.scan(/\p{Han}+/).join
    # If it ended up duplicated like "齊齊", collapse consecutive duplicates.
    if han.length >= 2 && han.chars.uniq.length == 1
      han = han[0]
    end
    han = han.presence || name.to_s.strip

    @rhyme_number = num
    @rhyme_name = han
    @rime_number = num
    @rime_name = han

    # The rime head character is the first Han character.
    @rime_char = han.to_s.each_char.find { |ch| ch.match?(/\p{Han}/) }

    # Rewrite the display title so it doesn't show duplicated/junk rime text.
    if @tone.present? && @rime_number.present? && @rime_name.present?
      @category = "#{@tone}｜#{@rime_number}.#{@rime_name}"
    end
  end

  def fetch_fields(ccid, fields)
    rows = CharacterProperty
      .where(character_codepoint_id: ccid, field: fields)
      .order(:id)
      .pluck(:field, :value)

    out = Hash.new { |h, k| h[k] = [] }
    rows.each do |field, value|
      v = value.to_s.strip
      next if v.empty?
      out[field] << v
    end
    out
  end

  def build_pairs_from_payload_raw(character_codepoint_ids)
    rows = CharacterProperty
      .where(source: DEFAULT_SOURCE, character_codepoint_id: character_codepoint_ids, field: "guangyun_payload_raw")
      .order(:id)
      .pluck(:character_codepoint_id, :value)

    out = Hash.new { |h, k| h[k] = [] }
    rows.each do |ccid, raw|
      raw_s = raw.to_s.strip
      next if raw_s.empty?

      # Split into fanqie + definition using the first "切".
      fanqie = nil
      definition = nil
      if (idx = raw_s.index("切"))
        fanqie = raw_s[0..idx].to_s.strip
        definition = raw_s[(idx + 1)..].to_s.strip
      else
        definition = raw_s
      end

      out[ccid] << { fanqie: fanqie.presence, definition: definition.presence }
    end

    out
  end

  def lookup_payload(q)
    s = q.to_s.strip
    return nil if s.empty?

    chr = nil
    if s.match?(/\AU\+[0-9A-Fa-f]{4,6}\z/)
      cp = s.sub(/\AU\+/i, "").to_i(16)
      chr = cp.chr(Encoding::UTF_8) rescue nil
    elsif s.length == 1
      chr = s
    end
    return nil if chr.nil?

    cc = CharacterCodepoint.find_by(chr: chr)
    return { missing: true, chr: chr } unless cc

    pairs = build_pairs_from_payload_raw([cc.id])[cc.id] || []

    {
      chr: cc.chr,
      codepoint: cc.codepoint,
      pairs: pairs
    }
  end
end
