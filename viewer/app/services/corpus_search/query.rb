# frozen_string_literal: true

require "json"

module CorpusSearch
  # Compatibility facade used by the current controller and views. Search
  # semantics and presentation settings are held by separate value objects.
  class Query
    attr_reader :search_definition, :presentation_options, :locale

    def self.from_params(params)
      filters = {
        nation: params[:nation],
        period: params[:period],
        region: params[:region],
        author: params[:author],
        year_start: params[:year_start],
        year_end: params[:year_end]
      }

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
        filters: filters,
        document_roles: params[:document_roles] || params[:roles],
        include_folders: params[:include_folders] || params[:folders],
        exclude_folders: params[:exclude_folders]
      )
    end

    def initialize(mode: "exact", term_a: nil, term_b: nil, distance: 200, context: 20,
                   order: "either", page: 1, per_page: 20, locale: I18n.locale, filters: {},
                   document_roles: nil, include_folders: nil, exclude_folders: nil,
                   search_definition: nil, presentation_options: nil)
      @search_definition = search_definition || SearchDefinition.new(
        mode: mode,
        term_a: term_a,
        term_b: term_b,
        distance: distance,
        order: order,
        metadata_filters: filters,
        document_roles: document_roles,
        include_folders: include_folders,
        exclude_folders: exclude_folders
      )
      @presentation_options = presentation_options || PresentationOptions.new(
        context: context,
        page: page,
        per_page: per_page
      )
      @locale = normalise_locale(locale)
    end

    def mode = @search_definition.mode
    def term_a = @search_definition.term_a
    def term_b = @search_definition.term_b
    def distance = @search_definition.distance
    def order = @search_definition.order
    def filters = @search_definition.manifest_filters
    def metadata_filters = @search_definition.metadata_filters
    def document_roles = @search_definition.document_roles
    def include_folders = @search_definition.include_folders
    def exclude_folders = @search_definition.exclude_folders
    def context = @presentation_options.context
    def page = @presentation_options.page
    def per_page = @presentation_options.per_page

    def valid?
      errors.empty?
    end

    def errors
      list = []
      list << I18n.t("corpus_search.errors.enter_term") if term_a.blank?
      list << I18n.t("corpus_search.errors.enter_second_term") if proximity? && term_b.blank?
      list << I18n.t("corpus_search.errors.term_too_long", max: 80) if [term_a, term_b].any? { |term| term.each_char.count > 80 }
      list
    end

    def proximity?
      @search_definition.proximity?
    end

    def exact?
      @search_definition.exact?
    end

    # Keep the current flat representation so prepared-search records and the
    # existing form continue to work during the staged refactor.
    def to_h
      {
        "schema_version" => SearchDefinition::SCHEMA_VERSION,
        "mode" => mode,
        "term_a" => term_a,
        "term_b" => term_b,
        "distance" => distance,
        "context" => context,
        "order" => order,
        "filters" => metadata_filters.reject { |_key, value| value.blank? },
        "document_roles" => document_roles,
        "include_folders" => include_folders,
        "exclude_folders" => exclude_folders
      }
    end

    def cache_key
      # Context still participates because the current hit cache stores rendered
      # snippets. Page and per-page do not change the match set.
      payload = {
        "version" => 2,
        "definition" => @search_definition.to_h,
        "context" => context,
        "locale" => @locale
      }
      CacheStore.hash_key(JSON.generate(payload))
    end

    def display_label
      if proximity?
        I18n.t("corpus_search.query.proximity_label", term_a: term_a, term_b: term_b, distance: distance)
      else
        term_a
      end
    end

    private

    def normalise_locale(value)
      candidate = value.to_s
      I18n.available_locales.map(&:to_s).include?(candidate) ? candidate : I18n.default_locale.to_s
    end
  end
end
