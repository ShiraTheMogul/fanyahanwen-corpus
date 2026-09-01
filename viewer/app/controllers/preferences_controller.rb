# frozen_string_literal: true

class PreferencesController < ApplicationController
  protect_from_forgery with: :exception

  # POST /preferences
def update
    # This controller is intentionally defensive:
    # - Some pages may submit a *subset* of preferences.
    # - If a param is missing, we keep the existing session value.

    if params.key?(:locale)
      requested_locale = params[:locale].to_s
      session[:locale] = requested_locale if InterfaceLocales.selectable?(requested_locale)
    end

    if params.key?(:mandarin_scheme)
      session[:mandarin_scheme] = safe_symbol(
        params[:mandarin_scheme],
        allowed: ([:original] + Phoneticization::Converters::MANDARIN_SCHEMES.keys)
      )
    end

    if params.key?(:cantonese_scheme)
      session[:cantonese_scheme] = safe_symbol(
        params[:cantonese_scheme],
        allowed: ([:original] + Phoneticization::Converters::CANTONESE_SCHEMES.keys)
      )
    end

    if params.key?(:laoguoyin_scheme)
      # Old National Pronunciation (老國音)
      # Stored as :original | :latin | :zhuyin | :ipa
      session[:laoguoyin_scheme] = safe_symbol(
        params[:laoguoyin_scheme],
        allowed: [:original, :latin, :zhuyin, :ipa]
      )
    end

    if params.key?(:ruby_enabled)
      session[:ruby_enabled] = (params[:ruby_enabled] == "1")
    end

    if params.key?(:ruby_source)
      new_ruby_source = safe_symbol(params[:ruby_source], allowed: ViewOptions.ruby_sources)

      # If the ruby source changed, any previously chosen token is likely invalid.
      if session[:ruby_source].present? && session[:ruby_source].to_s != new_ruby_source.to_s
        session[:ruby_token] = nil
      end

      session[:ruby_source] = new_ruby_source
    end

    if params.key?(:ruby_orientation)
      session[:ruby_orientation] = safe_symbol(params[:ruby_orientation], allowed: ViewOptions::RUBY_ORIENTATIONS)
    end

    if params.key?(:ruby_side)
      session[:ruby_side] = safe_symbol(params[:ruby_side], allowed: [:right, :left])
    end

    if params.key?(:ruby_token)
      session[:ruby_token] = params[:ruby_token].to_s.strip.presence
    end

    if params.key?(:script_mode)
      session[:script_mode] = safe_symbol(params[:script_mode], allowed: CharacterStandards.allowed_modes)
    end

    if params.key?(:han_font)
      session[:han_font] = safe_symbol(
        params[:han_font],
        allowed: HanFonts.allowed_keys.presence || [HanFonts.default_key]
      )
    end

    if params.key?(:han_font_scope)
      session[:han_font_scope] = safe_symbol(params[:han_font_scope], allowed: HanFonts.allowed_scopes)
    end

    if params.key?(:han_font_warn_missing)
      session[:han_font_warn_missing] = (params[:han_font_warn_missing] == "1")
    end

    selected_key = (session[:han_font].presence || HanFonts.default_key)
    selected_key = selected_key.to_s.strip.downcase.tr(" ", "_").to_sym

    respond_to do |format|
      format.json do
        render json: {
          ok: true,
          han_font_key: selected_key.to_s,
          han_font_primary: HanFonts.family_for(selected_key),
          han_font_family: HanFonts.family_for(selected_key),
          han_font_stack: HanFonts.stack_for(selected_key),
          han_font_scope: (session[:han_font_scope].presence || HanFonts.default_scope).to_s,
          han_font_warn_missing: (session.key?(:han_font_warn_missing) ? session[:han_font_warn_missing] : true),
          notice: I18n.t("common.notices.font_updated")
        }
      end

      format.html do
        # Return to the page the user was on (feels like "refresh").
        return_to = params[:return_to].presence
        redirect_to(return_to || request.referer || root_path)
      end
    end
  end

  private

  # Convert a string like "Gwoyeu" or "gwoyeu" into a symbol like :gwoyeu,
  # and ensure it is in the allow-list.
  #
  # We normalise BOTH the incoming value and the allow-list so you don't get
  # bitten by String-vs-Symbol mismatches.
  def safe_symbol(value, allowed:)
    sym = value.to_s.strip.downcase.tr(" ", "_").to_sym
    allowed_syms = Array(allowed).map { |a| a.to_s.strip.downcase.tr(" ", "_").to_sym }
    allowed_syms.include?(sym) ? sym : allowed_syms.first
  end
end
