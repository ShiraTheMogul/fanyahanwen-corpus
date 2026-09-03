# frozen_string_literal: true

module ApplicationHelper
  # ------------------------------------------------------------------
  # Han-script display conversion
  # ------------------------------------------------------------------
  # We store the user's choice in session[:script_mode]. CharacterStandards is
  # the single registry/service that knows how each profile is implemented.

  def current_script_mode
    raw = session[:script_mode]
    raw = :original if raw.blank?
    raw.to_s.strip.downcase.to_sym
  end

  def han_script_interface?
    InterfaceLocales.han_script?(I18n.locale)
  end

  def translated_interface_label(translation_key, ornament_key:)
    t(translation_key, default: "").presence || t(ornament_key)
  end

  def show_han_ornament?
    !han_script_interface?
  end

  def view_text(text)
    return "" if text.nil?
    convert_script(text.to_s)
  end

  def convert_script(text)
    CharacterStandards.convert(text, current_script_mode)
  end

  private

  def render_source(source)
    url = PropertySources.url_for(source)
    return source.to_s if url.nil?

    link_to(source.to_s, url, target: "_blank", rel: "noopener")
  end
end
