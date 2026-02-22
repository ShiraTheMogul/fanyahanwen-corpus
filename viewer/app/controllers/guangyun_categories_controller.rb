# frozen_string_literal: true

# Browse Guangyun entries by category (tone + rime).
#
# IMPORTANT (Rails routing gotcha)
# ------------------------------
# Rails treats a dot in a path segment as the "format" separator.
# If we put a category like "上平聲｜20.幽" into the URL segment, Rails will parse it as:
#   category="上平聲｜20"  format="幽"
# and then our lookups fail.
#
# Fix: keep the DB value as "上平聲｜20.幽", but use a dot-free route key in URLs:
#   "上平聲｜20｜幽"
# Then, in the controller, translate route key -> DB value.
class GuangyunCategoriesController < ApplicationController
  DEFAULT_PER = 50
  MAX_PER = 200
  DEFAULT_SOURCE = "Guangyun (Siku)"

  before_action :load_category, only: [:show, :chars]
  before_action :load_pagination, only: [:show, :chars]

  def index
    # Keep this page cheap: fetch distinct category strings only.
    scope = CharacterProperty.where(source: DEFAULT_SOURCE, field: "guangyun_category")
    @categories = scope.select(:value).distinct.order(:value).pluck(:value)

    tone_order = ["上平聲", "下平聲", "上聲", "去聲", "入聲"]
    @tone_groups = tone_order.index_with { [] }

    @categories.each do |cat|
      tone, rest = cat.to_s.split("｜", 2)
      tone = tone.to_s.strip
      next if tone.empty? || rest.to_s.strip.empty?

      num = nil
      rhyme = rest.to_s.strip
      if (m = rhyme.match(/\A(\d+)\.(.+)\z/))
        num = m[1].to_i
        rhyme = m[2].to_s.strip
      end

      # Dot-free route key so Rails doesn't eat the suffix as "format".
      route_key = if num
        "#{tone}｜#{num}｜#{rhyme}"
      else
        # fallback: still remove dots to be safe
        "#{tone}｜#{rhyme}".tr(".", "·")
      end

      entry = { category: cat, route_key: route_key, number: num, rhyme: rhyme }
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
    base = CharacterProperty.where(source: DEFAULT_SOURCE, field: "guangyun_category", value: @category)
    @total = base.select(:character_codepoint_id).distinct.count
    @category_rows_exist = base.exists?
  end

  def chars
    base = CharacterProperty.where(source: DEFAULT_SOURCE, field: "guangyun_category", value: @category)
    @total = base.select(:character_codepoint_id).distinct.count

    @characters = CharacterCodepoint
      .joins(:character_properties)
      .where(character_properties: { source: DEFAULT_SOURCE, field: "guangyun_category", value: @category })
      .distinct
      .order(:codepoint)
      .limit(@per)
      .offset((@page - 1) * @per)
      .to_a

    ids = @characters.map(&:id)
    @guangyun = build_guangyun_snippets(ids)

    render layout: false
  end

  private

  def load_category
    raw = params[:category].to_s.strip
    raise ActiveRecord::RecordNotFound if raw.blank?

    # Accept either:
    # - DB value:   上平聲｜20.幽
    # - Route key:  上平聲｜20｜幽
    if raw.include?("｜")
      parts = raw.split("｜")
      if parts.length == 3 && parts[1].match?(/\A\d+\z/)
        tone = parts[0].to_s.strip
        num = parts[1].to_i
        rhyme = parts[2].to_s.strip
        @category = "#{tone}｜#{num}.#{rhyme}"
        @route_key = raw
        return
      end
    end

    @category = raw
    @route_key = raw.tr(".", "·")
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

  def build_guangyun_snippets(character_codepoint_ids)
    return {} if character_codepoint_ids.empty?

    # Use the real payloads.
    # We still display Fanqie and Definition separately in the table,
    # but derive them from guangyun_payload_raw rather than trusting
    # pre-split rows.
    rows = CharacterProperty
      .where(
        source: DEFAULT_SOURCE,
        character_codepoint_id: character_codepoint_ids,
        field: "guangyun_payload_raw"
      )
      .order(:id)
      .pluck(:character_codepoint_id, :value)

    out = Hash.new { |h, k| h[k] = { pairs: [] } }
    rows.each do |ccid, payload|
      fanqie, definition = split_payload(payload)
      out[ccid][:pairs] << { fanqie: fanqie.presence, definition: definition.presence }
    end

    out
  end

  def split_payload(payload)
    s = payload.to_s.strip
    return [nil, ""] if s.empty?

    # Everything up to the FIRST '切' (inclusive) is fanqie.
    idx = s.index("切")
    return [nil, s] if idx.nil?

    fanqie = s[0..idx].strip
    definition = s[(idx + 1)..].to_s.strip
    [fanqie, definition]
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

    snippet = build_guangyun_snippets([cc.id])[cc.id]
    category = CharacterProperty
      .where(source: DEFAULT_SOURCE, character_codepoint_id: cc.id, field: "guangyun_category")
      .limit(1)
      .pluck(:value)
      .first

    {
      chr: cc.chr,
      codepoint: cc.codepoint,
      category: category,
      pairs: (snippet && snippet[:pairs]) ? snippet[:pairs] : []
    }
  end
end
