# frozen_string_literal: true

class ApplicationController < ActionController::Base
  helper PhoneticizationHelper
  helper DailyReadingsHelper

  before_action :ensure_font_defaults

  private

  # Ensure font preferences always have sane defaults.
  #
  # We set these only once per session; user choices persist.
  def ensure_font_defaults
    session[:han_font] = HanFonts.default_key unless session.key?(:han_font)
    session[:han_font_scope] = HanFonts.default_scope unless session.key?(:han_font_scope)
    session[:han_font_warn_missing] = true unless session.key?(:han_font_warn_missing)
  end
end
