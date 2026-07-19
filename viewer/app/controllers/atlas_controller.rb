# frozen_string_literal: true

class AtlasController < ApplicationController
  helper AtlasHelper

  def index
    @store = Atlas::EntryStore.default
    @store.validate!
    @hierarchy = Atlas::CorpusHierarchy.default
    @hierarchy.validate!(entry_store: @store)
    @node = @hierarchy.find!(params[:path])
    @breadcrumbs = @hierarchy.ancestors(@node)
    @node_entry = @node.entry_id && @store.find(@node.entry_id)
    @child_rows = @node.children.map do |child|
      entry = child.entry_id && @store.find(child.entry_id)
      {
        node: child,
        entry: entry,
        published: entry && @store.article_exists?(entry)
      }
    end
  end

  def show
    @store = Atlas::EntryStore.default
    @entry = @store.find!(params[:id])
    @article = @store.load(@entry, locale: I18n.locale)
    prepare_show
  end

  def preview
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

    @hierarchy = Atlas::CorpusHierarchy.default
    @placement_nodes = @entry.placements.filter_map { |path| @hierarchy.find(path) }
    @primary_placement = @placement_nodes.first
    @atlas_breadcrumbs = @primary_placement ? @hierarchy.ancestors(@primary_placement) : []
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
