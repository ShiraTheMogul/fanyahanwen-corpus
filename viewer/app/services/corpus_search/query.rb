# frozen_string_literal: true

require "json"
module CorpusSearch
  # Sanitised representation of a search form submission.
  class Query
    MODES = %w[exact proximity].freeze
    ORDERS = %w[either a_before_b b_before_a].freeze

    attr_reader :mode, :term_a, :term_b, :distance, :context, :order, :filters,
                :page, :per_page, :locale

    def self.from_params(params)
      new(
        mode: params[:mode],
        term_a: params[:term_a],
        term_b: params[:term_b],
        distance: params[:distance],
        context: params[:context],
        order: params[:order],
        page: params[:page],
        per_page: params[:per_page],
        locale: I18n.locale,
        filters: {
          nation: params[:nation],
          period: params[:period],
          region: params[:region],
          author: params[:author],
          year_start: params[:year_start],
          year_end: params[:year_end]
        }
      )
    end

    def initialize(mode: "exact", term_a: nil, term_b: nil, distance: 200, context: 20,
                   order: "either", page: 1, per_page: 20, locale: I18n.locale, filters: {})
      @mode = MODES.include?(mode.to_s) ? mode.to_s : "exact"
      @term_a = term_a.to_s.strip
      @term_b = term_b.to_s.strip
      @distance = clamp_integer(distance, default: 200, min: 1, max: 5_000)
      @context = clamp_integer(context, default: 20, min: 0, max: 200)
      @order = ORDERS.include?(order.to_s) ? order.to_s : "either"
      @page = clamp_integer(page, default: 1, min: 1, max: 100_000)
      @per_page = clamp_integer(per_page, default: 20, min: 1, max: 50)
      @locale = normalise_locale(locale)
      @filters = filters.to_h.transform_keys(&:to_s).transform_values { |value| value.to_s.strip }
    end

    def valid?
      errors.empty?
    end

    def errors
      list = []
      list << I18n.t("corpus_search.errors.enter_term") if @term_a.blank?
      list << I18n.t("corpus_search.errors.enter_second_term") if proximity? && @term_b.blank?
      list << I18n.t("corpus_search.errors.term_too_long", max: 80) if [@term_a, @term_b].any? { |term| term.each_char.count > 80 }
      list
    end

    def proximity?
      @mode == "proximity"
    end

    def exact?
      @mode == "exact"
    end

    def to_h
      {
        "mode" => @mode,
        "term_a" => @term_a,
        "term_b" => @term_b,
        "distance" => @distance,
        "context" => @context,
        "order" => @order,
        "filters" => @filters.reject { |_key, value| value.blank? }
      }
    end

    def cache_key
      CacheStore.hash_key(JSON.generate(to_h.merge("_locale" => @locale)))
    end

    def display_label
      if proximity?
        I18n.t("corpus_search.query.proximity_label", term_a: @term_a, term_b: @term_b, distance: @distance)
      else
        @term_a
      end
    end

    private

    def normalise_locale(value)
      candidate = value.to_s
      I18n.available_locales.map(&:to_s).include?(candidate) ? candidate : I18n.default_locale.to_s
    end

    def clamp_integer(value, default:, min:, max:)
      integer = Integer(value)
      [[integer, min].max, max].min
    rescue ArgumentError, TypeError
      default
    end
  end
end
