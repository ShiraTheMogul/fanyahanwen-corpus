# frozen_string_literal: true

module ApplicationHelper
  # ------------------------------------------------------------------
  # Chinese script conversion (Traditional / Simplified)
  # ------------------------------------------------------------------
  # We store the user's choice in `session[:script_mode]`.
  #
  # Values:
  #   :original    -> show text as stored
  #   :traditional -> convert to Traditional (best-effort)
  #   :simplified  -> convert to Simplified (best-effort)
  #
  # The important promise: conversion must NEVER crash page rendering.
  #

  def current_script_mode
    raw = session[:script_mode]
    raw = :original if raw.blank?
    # Important: keep the stored value flexible.
    # If the form ever submits "Simplified" (capitalized), we still want
    # the mode to become :simplified.
    raw.to_s.strip.downcase.to_sym
  end

  # Use this in views any time you output dictionary text.
  # It applies the user's "Chinese script" setting.
  def view_text(text)
    return "" if text.nil?
    convert_script(text.to_s)
  end

  def convert_script(text)
    mode = current_script_mode
    return text if text.blank? || mode == :original

    case mode
    when :traditional
      # 1) Try the `chinese_convt` gem if it is available
      # 2) Fall back to a Unihan-based per-character mapping
      chinese_convt_call(:traditional, text) || unihan_script_convert(text, :traditional)
    when :simplified
      chinese_convt_call(:simplified, text) || unihan_script_convert(text, :simplified)
    else
      text
    end
  end

  private

  # One-time discovery cache.
  #
  # We memoize a hash like:
  #   { target: <ModuleOrInstance>, trad: :tify, simp: :sify }
  #
  # or nil if we can't find a converter.
  def chinese_convt_discovery
    return @__chinese_convt_discovery if defined?(@__chinese_convt_discovery)

    begin
      require "chinese_convt"
    rescue LoadError
      @__chinese_convt_discovery = nil
      return nil
    end

    trad_methods = %i[tify to_traditional toTraditional s2t trad traditional]
    simp_methods = %i[sify to_simplified toSimplified t2s simp simplified]

    candidates = []

    # Try the obvious constant names first.
    %w[ChineseConvt ChineseConv OpenCC Opencc].each do |name|
      begin
        candidates << Object.const_get(name)
      rescue NameError
        # ignore
      end
    end

    # Then: scan for anything that *sounds* like a converter.
    Object.constants.grep(/Chinese|Convt|Conv|OpenCC/i).each do |const_name|
      begin
        candidates << Object.const_get(const_name)
      rescue NameError
        # ignore
      end
    end

    candidates.compact!
    candidates.uniq!

    # 1) Module/Class methods.
    candidates.each do |mod|
      trad = trad_methods.find { |m| mod.respond_to?(m) }
      simp = simp_methods.find { |m| mod.respond_to?(m) }
      next unless trad || simp
      @__chinese_convt_discovery = { target: mod, trad: trad, simp: simp }
      return @__chinese_convt_discovery
    end

    # 2) Instance methods (instantiate no-arg classes).
    candidates.each do |mod|
      next unless mod.is_a?(Class)
      inst =
        begin
          mod.new
        rescue StandardError
          nil
        end
      next unless inst

      trad = trad_methods.find { |m| inst.respond_to?(m) }
      simp = simp_methods.find { |m| inst.respond_to?(m) }
      next unless trad || simp
      @__chinese_convt_discovery = { target: inst, trad: trad, simp: simp }
      return @__chinese_convt_discovery
    end

    @__chinese_convt_discovery = nil
  rescue StandardError
    @__chinese_convt_discovery = nil
  end

  def chinese_convt_call(direction, text)
    found = chinese_convt_discovery
    return nil unless found

    target = found[:target]
    method_name = (direction == :traditional ? found[:trad] : found[:simp])
    return nil if method_name.nil?

    target.public_send(method_name, text.to_s)
  rescue StandardError
    nil
  end

  # ------------------------------------------------------------------
  # Fallback: Unihan kSimplifiedVariant / kTraditionalVariant mapping
  # ------------------------------------------------------------------
  # Why this exists:
  # - `chinese_convt` is a small gem with inconsistent APIs across forks.
  # - On some Windows setups it quietly fails to load, and we don't want
  #   "Convert text: Simplified" to become a no-op.
  #
  # This fallback uses the *data you already imported*:
  # CharacterProperty rows from Unihan_Variants.
  #
  # Limits:
  # - This is a *per-character* mapping. It does not do context-aware
  #   conversions (like OpenCC). For a dictionary viewer, that is fine.
  def unihan_script_convert(text, mode)
    str = text.to_s
    return str if str.empty?

    map = unihan_script_map(mode)
    return str if map.nil? || map.empty?

    str.each_char.map { |ch| map[ch] || ch }.join
  rescue StandardError
    str
  end

  # Build and cache a Hash like:
  #   { "漢" => "汉", "語" => "语", ... }
  #
  # We cache it because building it requires a DB query.
  def unihan_script_map(mode)
    mode = mode.to_s.downcase.to_sym
    field =
      case mode
      when :simplified
        "kSimplifiedVariant"
      when :traditional
        "kTraditionalVariant"
      else
        nil
      end
    return {} if field.nil?

    cache_key = "unihan_script_map:v1:#{field}"

    Rails.cache.fetch(cache_key) do
      # 1) Pull (character_id, "U+4E9A ...") pairs from the DB.
      rows = CharacterProperty.where(source: "Unihan_Variants", field: field)
                             .pluck(:character_codepoint_id, :value)

      ids = rows.map(&:first).uniq
      id_to_chr = CharacterCodepoint.where(id: ids).pluck(:id, :chr).to_h

      map = {}
      rows.each do |char_id, raw_value|
        base_chr = id_to_chr[char_id]
        next if base_chr.blank?

        # Unihan usually gives one or more codepoints like "U+4E9A U+...".
        token = raw_value.to_s.strip.split(/\s+/).first
        next if token.blank?

        target = unihan_token_to_char(token)
        next if target.nil?

        map[base_chr] = target
      end

      map
    end
  rescue StandardError
    {}
  end

  # Convert "U+4E9A" into "亚".
  # If the token isn't in that format, we treat it as a literal char.
  def unihan_token_to_char(token)
    t = token.to_s.strip
    return nil if t.empty?

    if t.match?(/\AU\+[0-9A-Fa-f]{4,6}\z/)
      codepoint = t.delete_prefix("U+").to_i(16)
      return codepoint.chr(Encoding::UTF_8)
    end

    # Some Unihan fields can contain literal chars (rare, but doesn't hurt).
    return t if t.length == 1

    nil
  rescue RangeError
    nil
  end
end
