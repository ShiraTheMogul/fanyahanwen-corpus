# frozen_string_literal: true

class GrammarController < ApplicationController
  helper GrammarHelper

  def index
    @store = Grammar::EntryStore.default
    @store.validate_catalogue!

    @sort = permitted_sort(params[:sort])
    @kind = params[:kind].presence
    @importance = params[:importance].presence
    @category = params[:category].presence
    @needed = params[:needed].to_s == "1"

    builder = Grammar::IndexBuilder.new(
      store: @store,
      locale: I18n.locale,
      pronunciation_source: session[:ruby_source].presence || :mandarin
    )
    @rows = builder.rows(
      sort: @sort,
      kind: @kind,
      importance: @importance,
      category: @category,
      needed: @needed
    )
    @groups = builder.groups(@rows, sort: @sort)
    @categories = @store.all.flat_map(&:categories).uniq.sort
    prepare_unlisted_submission if params[:unlisted].to_s == "1"
  end

  def show
    @store = Grammar::EntryStore.default
    @entry = @store.find!(params[:id])
    @article = @store.load(@entry, locale: I18n.locale)
    prepare_show
  end

  def preview
    @store = Grammar::EntryStore.default
    @entry = if params[:unlisted_entry].to_s == "1"
               Grammar::ProposedEntryBuilder.new(store: @store).build!(
                 kind: params[:entry_kind],
                 headword: params[:entry_headword],
                 title: params[:entry_title],
                 parent_id: params[:entry_parent_id],
                 label: params[:entry_label]
               )
             else
               @store.find!(params[:entry_id])
             end
    requested_locale = params[:locale].presence || I18n.locale.to_s
    document = Grammar::MarkdownDocument.parse(params[:raw_markdown].to_s)

    @article = Grammar::EntryStore::LoadedEntry.new(
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
  rescue Psych::SyntaxError, ArgumentError, Grammar::ProposedEntryBuilder::ValidationError => e
    render plain: "Grammar preview error: #{e.message}", status: :unprocessable_entity
  end

  def template
    store = Grammar::EntryStore.default
    entry = store.find!(params[:id])
    locale = params[:locale].presence || I18n.locale.to_s
    markdown = store.submission_markdown_for(entry, locale: locale)

    send_data(
      markdown,
      filename: "#{entry.id}.#{locale}.md",
      type: "text/markdown; charset=utf-8",
      disposition: "attachment"
    )
  end

  private

  def prepare_show
    @canonical_article =
      if @article.translated?
        @store.load(@entry, locale: Grammar::EntryStore::SOURCE_LOCALE)
      else
        @article
      end

    @children = @store.children_for(@entry.id)
    @siblings = @entry.parent_id ? @store.children_for(@entry.parent_id) : @children
    @parent_entry = @store.find(@entry.parent_id) if @entry.parent_id
    @related_entries = @store.related_for(
      @entry,
      metadata: @canonical_article.metadata
    )
    @character_frame = Grammar::CharacterFrame.for(@entry.headword) if @entry.single_character?
    @article_searches = (
      @entry.corpus_searches +
      Array(@article.metadata["corpus_searches"]).select { |value| value.is_a?(Hash) }
    ).uniq

    @published_locales = InterfaceLocales::ALL.map(&:to_s).select do |locale|
      @store.article_exists?(@entry, locale: locale)
    end
    @submission_action = submission_action
    @submission_locale = I18n.locale.to_s
    @submission_markdown = @store.submission_markdown_for(
      @entry,
      locale: @submission_locale
    )
  end

  def submission_action
    locale = I18n.locale.to_s
    if @store.article_exists?(@entry, locale: locale)
      "edit"
    elsif locale == Grammar::EntryStore::SOURCE_LOCALE
      "create"
    else
      "translate"
    end
  end

  def prepare_unlisted_submission
    @show_unlisted_submission = true
    @published_locales = []
    @submission_action = "create"
    @submission_locale = Grammar::EntryStore::SOURCE_LOCALE
    @submission_markdown = @store.template_body_for("function_word")
    @unlisted_templates = Grammar::Entry::KINDS.index_with do |kind|
      @store.template_body_for(kind)
    end
    @unlisted_existing_ids = @store.existing_ids
    @unlisted_parent_options = @store.all.select { |entry| entry.kind == "function_word" }
  end

  def permitted_sort(value)
    Grammar::IndexBuilder::SORTS.include?(value.to_s) ? value.to_s : "radical"
  end
end
