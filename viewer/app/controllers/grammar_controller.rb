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
    @identifier_result = identifier_result if params[:generate_id].present?
  end

  def show
    @store = Grammar::EntryStore.default
    @entry = @store.find!(params[:id])
    @article = @store.load(@entry, locale: I18n.locale)
    prepare_show
  end

  def preview
    @store = Grammar::EntryStore.default
    @entry = @store.find!(params[:entry_id])
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
  rescue Psych::SyntaxError, ArgumentError => e
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

  def identifier_result
    kind = params[:id_kind].presence || "function_word"
    headword = params[:id_headword].to_s
    label = params[:id_label].to_s
    parent_id = params[:id_parent].to_s.presence
    candidate = Grammar::Identifier.generate(
      kind: kind,
      headword: headword,
      parent_id: parent_id,
      label: label
    )
    collision = Grammar::Identifier.collision?(candidate, @store.existing_ids)

    {
      candidate: candidate,
      collision: collision,
      next_available: collision ? Grammar::Identifier.next_available(candidate, @store.existing_ids) : candidate
    }
  end

  def permitted_sort(value)
    Grammar::IndexBuilder::SORTS.include?(value.to_s) ? value.to_s : "radical"
  end
end
