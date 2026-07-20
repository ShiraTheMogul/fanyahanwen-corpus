# frozen_string_literal: true

class AtlasController < ApplicationController
  helper AtlasHelper

  def index
    @catalogue = Atlas::Catalogue.default
    resolve_legacy_path!
    return if performed?

    @query = params[:q].to_s.strip
    @macro_region_id = params[:macro_region].to_s.presence
    @period_id = params[:period].to_s.presence

    @macro_region = @macro_region_id && @catalogue.macro_region!(@macro_region_id)
    @period = if @period_id
                raise ActiveRecord::RecordNotFound, "A period requires a macro-region" unless @macro_region
                @catalogue.period!(@macro_region_id, @period_id)
              end
    @period_ancestors = @period ? @catalogue.period_ancestors(@macro_region_id, @period_id) : []

    if @query.present?
      @view_mode = :search
      @entries = @catalogue.search(
        @query,
        macro_region_id: @macro_region_id,
        period_id: @period_id
      )
    elsif @period
      @view_mode = :period
      @child_periods = @catalogue.periods_for(@macro_region_id, parent_id: @period_id)
      @entries = @catalogue.entries_for(
        macro_region_id: @macro_region_id,
        period_id: @period_id,
        direct: @child_periods.any?
      )
    elsif @macro_region
      @view_mode = :macro_region
      @periods = @catalogue.periods_for(@macro_region_id)
    else
      @view_mode = :landing
      @macro_regions = @catalogue.macro_regions
    end
  end

  def show
    @catalogue = Atlas::Catalogue.default
    @store = Atlas::EntryStore.default
    @entry = @store.find(params[:id])

    unless @entry
      redirect = @catalogue.period_redirect_for_legacy_id(params[:id])
      if redirect
        query = {
          macro_region: redirect.fetch("macro_region_id"),
          period: redirect.fetch("period_id")
        }.to_query
        redirect_to "/atlas?#{query}", status: :moved_permanently
        return
      end
      raise ActiveRecord::RecordNotFound, "Unknown atlas polity or period"
    end

    @article = @store.load(@entry, locale: I18n.locale)
    prepare_show
  end

  def preview
    @catalogue = Atlas::Catalogue.default
    @store = Atlas::EntryStore.default
    @entry = @store.find!(params[:entry_id])
    requested_locale = params[:locale].presence || I18n.locale.to_s
    document = Grammar::MarkdownDocument.parse(params[:raw_markdown].to_s)

    @article = Atlas::EntryStore::LoadedEntry.new(
      entry: @entry,
      document: document,
      requested_locale: requested_locale,
      locale: requested_locale,
      path: nil,
      fallback: false,
      revision: "preview"
    )
    @preview = true
    prepare_show
    render :show
  rescue Psych::SyntaxError, ArgumentError, ActiveRecord::RecordNotFound => error
    render plain: "Atlas preview error: #{error.message}", status: :unprocessable_entity
  end

  def template
    store = Atlas::EntryStore.default
    entry = store.find!(params[:id])
    locale = params[:locale].presence || I18n.locale.to_s
    markdown = store.submission_markdown_for(entry, locale: locale)

    send_data(
      markdown,
      filename: "atlas-#{entry.id}.#{locale}.md",
      type: "text/markdown; charset=utf-8",
      disposition: "attachment"
    )
  end

  private

  def resolve_legacy_path!
    path = params[:path].to_s
    return if path.blank? || params[:macro_region].present? || params[:period].present?

    root, period_name, final_component = path.split("/", 3)
    macro_region = @catalogue.macro_region_for_root(root)
    raise ActiveRecord::RecordNotFound, "Unknown atlas path" if macro_region.blank?

    if final_component.present?
      entry = @catalogue.find_by_corpus(root: root, period: period_name, polity: final_component)
      if entry
        redirect_to "/atlas/#{ERB::Util.url_encode(entry.id)}", status: :moved_permanently
        return
      end

      corpus_path = [root, "clean", period_name, final_component].join("/")
      typed_period = @catalogue.period_for_corpus_path(corpus_path)
      if typed_period
        params[:macro_region] = macro_region
        params[:period] = typed_period.fetch("id")
        return
      end

      # Older Japanese navigation inserted 日本 between the corpus root and the
      # actual period, for example 日本漢文/日本/江戸時代.
      if @catalogue.period(macro_region, final_component)
        params[:macro_region] = macro_region
        params[:period] = final_component
        return
      end

      raise ActiveRecord::RecordNotFound, "Unknown atlas polity or period"
    end

    params[:macro_region] = macro_region
    if period_name.present?
      typed_period = @catalogue.period_for_corpus_path([root, "clean", period_name].join("/"))
      params[:period] = typed_period ? typed_period.fetch("id") : period_name
    end
  end

  def prepare_show
    @canonical_article = if @article.translated?
                           @store.load(@entry, locale: Atlas::EntryStore::SOURCE_LOCALE)
                         else
                           @article
                         end
    @related_entries = @store.related_for(@entry, metadata: @canonical_article.metadata)
    @article_searches = Atlas::ArticleSearches.for(entry: @entry, article_metadata: @canonical_article.metadata)
    @published_locales = InterfaceLocales::ALL.map(&:to_s).select do |locale|
      @store.article_exists?(@entry, locale: locale)
    end
    @submission_action = submission_action
    @submission_locale = I18n.locale.to_s
    @submission_markdown = @store.submission_markdown_for(@entry, locale: @submission_locale)

    @primary_macro_region_id = @entry.macro_regions.first
    @primary_macro_region = @primary_macro_region_id && @catalogue.macro_region(@primary_macro_region_id)
    @primary_period_id = @entry.periods.last
    @primary_period = if @primary_macro_region_id && @primary_period_id
                        @catalogue.period(@primary_macro_region_id, @primary_period_id)
                      end
    @primary_period_ancestors = if @primary_period
                                  @catalogue.period_ancestors(@primary_macro_region_id, @primary_period_id)
                                else
                                  []
                                end
  end

  def submission_action
    locale = I18n.locale.to_s
    if @store.article_exists?(@entry, locale: locale)
      "edit"
    elsif locale == Atlas::EntryStore::SOURCE_LOCALE
      "create"
    else
      "translate"
    end
  end
end
