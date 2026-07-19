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

    if @query.present?
      @view_mode = :search
      @entries = @catalogue.search(
        @query,
        macro_region_id: @macro_region_id,
        period_id: @period_id
      )
    elsif @period
      @view_mode = :period
      @entries = @catalogue.entries_for(macro_region_id: @macro_region_id, period_id: @period_id)
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
    @entry = @store.find!(params[:id])
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
  rescue Psych::SyntaxError, ArgumentError, ActiveRecord::RecordNotFound => e
    render plain: "Atlas preview error: #{e.message}", status: :unprocessable_entity
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

    root, period, polity = path.split("/", 3)
    macro_region = @catalogue.macro_region_for_root(root)
    raise ActiveRecord::RecordNotFound, "Unknown atlas path" if macro_region.blank?

    if polity.present?
      entry = @catalogue.find_by_corpus(root: root, period: period, polity: polity)
      if entry
        redirect_to "/atlas/#{ERB::Util.url_encode(entry.id)}", status: :moved_permanently
        return
      end

      # Older corpus navigation sometimes inserted a broad polity folder between
      # the corpus root and its actual period, for example
      # 日本漢文/日本/江戸時代. Treat the final component as the period when it
      # is present in the compiled catalogue.
      if @catalogue.period(macro_region, polity)
        params[:macro_region] = macro_region
        params[:period] = polity
        return
      end

      raise ActiveRecord::RecordNotFound, "Unknown atlas polity or period"
    end

    params[:macro_region] = macro_region
    params[:period] = period if period.present?
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
    @primary_period_id = @entry.periods.first
    @primary_period = if @primary_macro_region_id && @primary_period_id
                        @catalogue.period(@primary_macro_region_id, @primary_period_id)
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
