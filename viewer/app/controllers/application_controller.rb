# frozen_string_literal: true

class ApplicationController < ActionController::Base
  helper PhoneticizationHelper
  helper DailyReadingsHelper

  around_action :use_interface_locale
  before_action :ensure_font_defaults

  private

  # Run the whole request inside the interface locale stored in the session.
  # Missing Literary Chinese keys fall back to the English source catalogue.
  def use_interface_locale(&action)
    allowed = I18n.available_locales.map(&:to_s)
    selected = session[:locale].to_s
    selected = I18n.default_locale.to_s unless allowed.include?(selected)

    I18n.with_locale(selected, &action)
  end

  # Ensure font preferences always have sane defaults.
  #
  # We set these only once per session; user choices persist.
  def ensure_font_defaults
    session[:han_font] = HanFonts.default_key unless session.key?(:han_font)
    session[:han_font_scope] = HanFonts.default_scope unless session.key?(:han_font_scope)
    session[:han_font_warn_missing] = true unless session.key?(:han_font_warn_missing)
  end
end
