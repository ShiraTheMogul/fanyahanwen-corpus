# frozen_string_literal: true

module AtlasHelper
  MARKDOWN_TAGS = GrammarHelper::MARKDOWN_TAGS
  MARKDOWN_ATTRIBUTES = GrammarHelper::MARKDOWN_ATTRIBUTES

  def atlas_entry_path_for(entry)
    "/atlas/#{ERB::Util.url_encode(entry.id)}"
  end


  def atlas_macro_region_path(macro_region_id)
    "/atlas?#{ { macro_region: macro_region_id }.to_query }"
  end

  def atlas_period_path(macro_region_id, period_id)
    "/atlas?#{ { macro_region: macro_region_id, period: period_id }.to_query }"
  end

  def atlas_search_path(query:, macro_region_id: nil, period_id: nil)
    values = { q: query, macro_region: macro_region_id, period: period_id }.compact
    "/atlas?#{values.to_query}"
  end

  def atlas_corpus_document_path(path)
    corpus_viewer_path(path.to_s.split("/"), format: nil)
  end

  def atlas_folder_search_url(node_or_path)
    folder = node_or_path.respond_to?(:corpus_path) ? node_or_path.corpus_path : node_or_path.to_s
    "/corpus/search?#{ { folders: [folder], roles: ["canonical"] }.to_query }"
  end

  def atlas_template_path_for(entry, locale: I18n.locale)
    "/atlas/#{ERB::Util.url_encode(entry.id)}/template?locale=#{ERB::Util.url_encode(locale)}"
  end

  def atlas_markdown(document)
    html = Grammar::MarkdownRenderer.render(document)
    sanitize(html, tags: MARKDOWN_TAGS, attributes: MARKDOWN_ATTRIBUTES)
  end

  def atlas_search_url(search)
    values = Grammar::MarkdownDocument.stringify_keys(search.to_h)
    mode = values["mode"].presence || "exact"
    first_term = values["term_a"].to_s
    second_term = values["term_b"].to_s
    alternative_terms = Array(values["terms"]).map(&:to_s).reject(&:blank?)
    order = values["order"].to_s

    if mode == "proximity" && order == "b_before_a"
      first_term, second_term = second_term, first_term
      order = "entered"
    elsif mode == "proximity"
      order = order == "a_before_b" ? "entered" : "any"
    end

    params = {
      mode: mode,
      q: (first_term if mode == "exact"),
      terms: (mode == "alternatives" ? alternative_terms : ([first_term, second_term] if mode == "proximity")),
      span: (values["distance"] if mode == "proximity"),
      order: (order if mode == "proximity"),
      punctuation: "ignore",
      characters: "common",
      roles: ["canonical"],
      context: values["context"],
      nation: values["nation"],
      polity: values["polity"],
      period: values["period"],
      region: values["region"],
      author: values["author"],
      year_start: values["year_start"],
      year_end: values["year_end"],
      folders: Array(values["folders"]).map(&:to_s).reject(&:blank?),
      exclude_folders: Array(values["exclude_folders"]).map(&:to_s).reject(&:blank?)
    }.compact
    "/corpus/search?#{params.to_query}"
  end

  def atlas_contributor_label(contributor)
    row = Grammar::MarkdownDocument.stringify_keys(contributor.to_h)
    name = row["name"].presence || t("atlas.credits.anonymous")
    role = t("atlas.credits.roles.#{row['role']}", default: row["role"].to_s.humanize)

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

  def atlas_apa_citation(article, request_url:, canonical_article: nil)
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
    author_text = authors.any? ? atlas_apa_names(authors) : "Fanya Hanwen Corpus"
    title = metadata["title"].presence || article.entry.title
    publication_date = metadata["published_at"].to_s
    year = publication_date[/\A\d{4}/] || metadata["updated_at"].to_s[/\A\d{4}/] || "n.d."

    if article.translated? && translators.any?
      original_year = canonical_metadata["published_at"].to_s[/\A\d{4}/]
      translation_note = " (#{atlas_apa_names(translators)}, Trans.)"
      original_note = original_year.present? ? " (Original work published #{original_year})" : ""
      "#{author_text}. (#{year}). #{title}#{translation_note}. In Fanya Hanwen Atlas. Fanya Hanwen Corpus.#{original_note} #{request_url}"
    else
      "#{author_text}. (#{year}). #{title}. In Fanya Hanwen Atlas. Fanya Hanwen Corpus. #{request_url}"
    end
  end

  def atlas_revision_label(article)
    article.revision.presence || "unpublished"
  end

  def atlas_year_label(year, approximate: false)
    return nil if year.nil?

    number = year.to_i
    label = number.negative? ? "#{number.abs} BCE" : "#{number} CE"
    approximate ? "c. #{label}" : label
  end

  def atlas_timespan_label(entry)
    span = entry.timespan
    start_label = atlas_year_label(span["start_year"], approximate: span["start_approx"] == true)
    end_label = span["ongoing"] == true ? t("atlas.metadata.present") : atlas_year_label(span["end_year"], approximate: span["end_approx"] == true)
    [start_label, end_label].compact.join("–").presence
  end

  private

  def atlas_apa_names(names)
    cleaned = Array(names).map(&:to_s).reject(&:blank?)
    return cleaned.first.to_s if cleaned.length <= 1
    return cleaned.join(" & ") if cleaned.length == 2

    "#{cleaned[0...-1].join(', ')}, & #{cleaned.last}"
  end
end
