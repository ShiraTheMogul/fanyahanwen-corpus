class TextbookApiController < ApplicationController
  protect_from_forgery with: :null_session

  def format_numeral
    n = Integer(params[:n])
    profile = Textbook::ConversionProfiles.fetch(params[:profile])

    unless profile.engine == "numerals" && profile.direction == "arabic_to_han"
      return render json: { ok: false, error: "Profile not for arabic_to_han numerals" }, status: 422
    end

    opts = profile.options || {}
    output = Zhengshu.format(n, use_you: !!opts["use_you"], use_abbrev: !!opts["use_abbrev"])
    render json: { ok: true, input: n, output: output }
  rescue ArgumentError, TypeError => e
    render json: { ok: false, error: e.message }, status: 422
  end

  def parse_numeral
    s = params[:s].to_s.strip
    profile = Textbook::ConversionProfiles.fetch(params[:profile])

    unless profile.engine == "numerals" && profile.direction == "han_to_arabic"
      return render json: { ok: false, error: "Profile not for han_to_arabic numerals" }, status: 422
    end

    opts = profile.options || {}
    value = ZhengshuParser.parse(
      s,
      allow_you: !!opts["allow_you"],
      allow_abbrev: !!opts["allow_abbrev"],
      allow_variants: opts.key?("allow_variants") ? !!opts["allow_variants"] : true
    )

    render json: { ok: true, input: s, output: value }
  rescue ArgumentError => e
    render json: { ok: false, error: e.message }, status: 422
  end
end
