# frozen_string_literal: true

module GrammarHelper
  MARKDOWN_TAGS = %w[
    p br h1 h2 h3 h4 h5 h6 strong em b i ul ol li blockquote pre code tt
    a hr table thead tbody tr th td details summary div section figure
    figcaption mark sup sub
  ].freeze
  MARKDOWN_ATTRIBUTES = %w[href title class id rel target].freeze

  def grammar_entry_path_for(entry)
    "/grammar/#{ERB::Util.url_encode(entry.id)}"
  end

  def grammar_template_path_for(entry, locale: I18n.locale)
    "/grammar/#{ERB::Util.url_encode(entry.id)}/template?locale=#{ERB::Util.url_encode(locale)}"
  end

  def grammar_markdown(document)
    html = Grammar::MarkdownRenderer.render(document)
    sanitize(html, tags: MARKDOWN_TAGS, attributes: MARKDOWN_ATTRIBUTES)
  end

  def grammar_status_label(status)
    t("grammar.statuses.#{status}")
  end

  def grammar_importance_label(value)
    return t("grammar.importance.unclassified") if value.blank?

    t("grammar.importance.#{value}", default: value.to_s.humanize)
  end

  def grammar_kind_label(value)
    t("grammar.kinds.#{value}", default: value.to_s.humanize)
  end

  def grammar_category_label(value)
    t("grammar.categories.#{value}", default: value.to_s.humanize)
  end

  def grammar_index_group_heading(group)
    case group.type
    when "radical"
      return t("grammar.index.other_entries") unless group.radical_number

      safe_join(
        [
          content_tag(:span, group.radical_glyph, class: "grammar-radical-glyph"),
          content_tag(:span, t("grammar.index.radical_heading", number: group.radical_number))
        ],
        " "
      )
    when "stroke"
      group.value.present? ? t("grammar.index.stroke_heading", count: group.value) : t("grammar.index.stroke_unknown")
    when "importance"
      grammar_importance_label(group.value)
    when "kind"
      group.value.present? ? grammar_kind_label(group.value) : t("grammar.index.kind_unknown")
    when "category"
      group.value.present? ? grammar_category_label(group.value) : t("grammar.index.category_unknown")
    when "pronunciation"
      group.value.presence || t("grammar.index.pronunciation_unknown")
    end
  end

  def grammar_search_url(search)
    values = Grammar::MarkdownDocument.stringify_keys(search.to_h)
    params = {
      mode: values["mode"].presence || "exact",
      term_a: values["term_a"],
      term_b: values["term_b"],
      order: values["order"],
      distance: values["distance"],
      context: values["context"],
      nation: values["nation"],
      period: values["period"],
      region: values["region"],
      author: values["author"],
      year_start: values["year_start"],
      year_end: values["year_end"]
    }.compact
    "/corpus/search?#{params.to_query}"
  end

  def grammar_contributor_label(contributor)
    row = Grammar::MarkdownDocument.stringify_keys(contributor.to_h)
    name = row["name"].presence || t("grammar.credits.anonymous")
    role = t("grammar.credits.roles.#{row['role']}", default: row["role"].to_s.humanize)

    content_tag(:span, class: "grammar-credit") do
      pieces = [content_tag(:strong, name), content_tag(:span, role, class: "grammar-credit-role")]
      if row["orcid"].present?
        pieces << link_to(
          "ORCID #{row['orcid']}",
          "https://orcid.org/#{ERB::Util.url_encode(row['orcid'])}",
          target: "_blank",
          rel: "noopener noreferrer",
          class: "grammar-orcid"
        )
      end
      pieces << content_tag(:time, row["date"], datetime: row["date"]) if row["date"].present?
      safe_join(pieces, " · ")
    end
  end

  def grammar_apa_citation(article, request_url:, canonical_article: nil)
    metadata = article.metadata
    canonical_metadata = canonical_article&.metadata || metadata
    canonical_contributors = Array(canonical_metadata["contributors"]).filter_map do |row|
      row.is_a?(Hash) ? Grammar::MarkdownDocument.stringify_keys(row) : nil
    end
    translation_contributors = Array(metadata["contributors"]).filter_map do |row|
      row.is_a?(Hash) ? Grammar::MarkdownDocument.stringify_keys(row) : nil
    end

    authors = canonical_contributors.select { |row| row["role"] == "author" }.map { |row| row["name"] }.compact
    translators = translation_contributors.select { |row| row["role"] == "translator" }.map { |row| row["name"] }.compact
    author_text = authors.any? ? apa_names(authors) : "Fanya Hanwen Corpus"
    title = metadata["title"].presence || article.entry.title
    publication_date = metadata["published_at"].to_s
    year = publication_date[/\A\d{4}/] || metadata["updated_at"].to_s[/\A\d{4}/] || "n.d."

    if article.translated? && translators.any?
      original_year = canonical_metadata["published_at"].to_s[/\A\d{4}/]
      translation_note = " (#{apa_names(translators)}, Trans.)"
      original_note = original_year.present? ? " (Original work published #{original_year})" : ""
      "#{author_text}. (#{year}). #{title}#{translation_note}. In Fanya Hanwen Literary Chinese Grammar Wiki. Fanya Hanwen Corpus.#{original_note} #{request_url}"
    else
      "#{author_text}. (#{year}). #{title}. In Fanya Hanwen Literary Chinese Grammar Wiki. Fanya Hanwen Corpus. #{request_url}"
    end
  end

  def grammar_revision_label(article)
    article.revision.presence || "unpublished"
  end

  private

  def apa_names(names)
    cleaned = Array(names).map(&:to_s).reject(&:blank?)
    return cleaned.first.to_s if cleaned.length <= 1
    return cleaned.join(" & ") if cleaned.length == 2

    "#{cleaned[0...-1].join(', ')}, & #{cleaned.last}"
  end
end
