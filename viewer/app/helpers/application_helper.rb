# frozen_string_literal: true

module ApplicationHelper
  # ------------------------------------------------------------------
  # Han-script display conversion
  # ------------------------------------------------------------------
  # We store the user's choice in `session[:script_mode]`.
  #
  # Values:
  #   :original    -> show text as stored
  #   :traditional -> convert to Traditional with OpenCC
  #   :simplified  -> convert to Simplified with OpenCC
  #   :wu_zhao     -> convert mapped characters to 則天文字
  #   :shinjitai   -> convert old-form characters to Japanese 新字体
  #   :singapore_1969 -> convert to Singapore's 1969 《簡體字表》 where encoded
  #   :erjian_1    -> Simplified Unicode + BabelStone Erjian 1 glyph overlay
  #   :erjian_2    -> Simplified Unicode + BabelStone Erjian 2 glyph overlay
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

  # True when the selected interface locale is written primarily in Han script.
  # In those locales the translation stands alone; an English-only ornamental
  # Han heading would otherwise be repeated beside it.
  def han_script_interface?
    InterfaceLocales.han_script?(I18n.locale)
  end

  # Use the translated label, falling back to the ornamental Han form only when
  # a catalogue has not yet supplied a translation.
  def translated_interface_label(translation_key, ornament_key:)
    t(translation_key, default: "").presence || t(ornament_key)
  end

  # Non-Han interfaces may retain the ornamental Han form beside the translation.
  def show_han_ornament?
    !han_script_interface?
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
      CharacterStandards.traditional(text)
    when :simplified
      CharacterStandards.simplified(text)
    when :singapore_1969
      # The 1969 table is keyed by traditional source forms. Normalise the
      # corpus text first so Simplified input can still reach the Singapore map.
      CharacterStandards.singapore_1969(CharacterStandards.traditional(text))
    when :wu_zhao
      CharacterStandards.wu_zhao(text)
    when :shinjitai
      # OpenCC's t2jp table is an old-form/Traditional -> 新字体 mapping.
      # Normalise Simplified input back to Traditional first so a corpus file
      # stored as, for example, 简体字 can still display as 簡体字.
      CharacterStandards.shinjitai(CharacterStandards.traditional(text))
    when :erjian_1, :erjian_2
      # BabelStone Erjian places 二簡字 glyphs at the Unicode positions of
      # ordinary simplified characters. The font layer is selected separately
      # in layouts/_dynamic_fonts.html.erb.
      CharacterStandards.simplified(text)
    else
      text
    end
  end

  private

  def render_source(source)
	  url = PropertySources.url_for(source)
	  return source.to_s if url.nil?

	  link_to(source.to_s, url, target: "_blank", rel: "noopener")
	end
end
