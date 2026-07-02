# frozen_string_literal: true

require "digest"

module CorpusSearchHelper
  # Renders the visible snippet while highlighting each matched term. Exact
  # searches receive one mark; proximity and OR searches use term_matches.
  def corpus_search_snippet(hit)
    left = hit["left_context"].to_s
    matched = hit["matched_text"].to_s
    right = hit["right_context"].to_s
    visible = [left, matched, right].join

    body_visible_start = hit["start_offset"].to_i - left.each_char.count
    ranges = highlighted_ranges(hit).filter_map do |range_start, range_end|
      relative_start = range_start.to_i - body_visible_start
      relative_end = range_end.to_i - body_visible_start
      next if relative_end <= 0 || relative_start >= visible.each_char.count

      [[relative_start, 0].max, [relative_end, visible.each_char.count].min]
    end

    render_highlighted_text(visible, merge_ranges(ranges))
  end

  # Building the small folder tree in one helper avoids one recursive partial
  # render (and one development-log line) per node while keeping the same HTML.
  def corpus_search_folder_tree(folder_tree, query)
    safe_join(Array(folder_tree&.roots).map { |node| corpus_search_folder_node(node, query, 0) })
  end

  def corpus_search_unique_equivalence_matches(hit)
    Array(hit["equivalence_matches"]).uniq do |match|
      [
        match["query_character"],
        match["source_character"],
        Array(match["mapping_path"]),
        Array(match["mapping_sources"])
      ]
    end
  end

  def corpus_search_equivalence_explanation(match)
    query_character = match["query_character"].to_s
    source_character = match["source_character"].to_s
    path = Array(match["mapping_path"]).join(" → ")
    sources = Array(match["mapping_sources"]).map do |source|
      t("corpus_search.equivalence_sources.#{source}", default: source.to_s.tr("_", " "))
    end.join(", ")

    safe_join([
      content_tag(:code, query_character),
      " → ",
      content_tag(:code, source_character),
      " — ",
      t("corpus_search.results.equivalence_via", sources: sources, path: path)
    ])
  end

  def corpus_search_analysis_metric_label(metric)
    t("corpus_search.analysis.metrics.#{metric}", default: metric.to_s.humanize)
  end

  def corpus_search_analysis_dimension_label(dimension)
    t("corpus_search.analysis.dimensions.#{dimension}", default: dimension.to_s.humanize)
  end

  def corpus_search_analysis_value(metric, value)
    number = value.to_f
    case metric.to_s
    when "document_prevalence"
      number_to_percentage(number * 100, precision: 2)
    when "occurrences_per_million"
      number_with_precision(number, precision: 2, strip_insignificant_zeros: true)
    else
      number_with_delimiter(number.round)
    end
  end

  def corpus_search_analysis_svg(report, chart)
    svg = report&.svg(chart)
    return nil if svg.blank?

    # The SVG is produced by the fixed application-owned R script. Base R's
    # graphics device escapes text labels before writing XML. Strip the XML
    # declaration and doctype before embedding the <svg> element in HTML.
    embedded = svg.sub(/\A.*?(?=<svg\b)/m, "")
    return nil if embedded.match?(/<(?:script|foreignObject)\b|\son[a-z]+\s*=/i)

    embedded.html_safe
  end

  def corpus_search_analysis_role_label(role)
    t("corpus_search.roles.#{role}", default: role.to_s.humanize)
  end

  def corpus_search_comparison_group_options(report, selected_dimension:, selected_group:)
    groups = CorpusSearch::ComparisonDefinition::DIMENSIONS.filter_map do |dimension|
      options = report.comparison_options(dimension)
      next if options.length < 2

      tag.optgroup(
        safe_join(options.map do |group|
          tag.option(
            group,
            value: group,
            selected: dimension.to_s == selected_dimension.to_s && group.to_s == selected_group.to_s,
            data: { dimension: dimension }
          )
        end),
        label: corpus_search_analysis_dimension_label(dimension),
        data: { dimension: dimension }
      )
    end

    safe_join(groups)
  end

  def corpus_search_comparison_effect_label(measure)
    t("corpus_search.comparison.effects.#{measure}", default: measure.to_s.humanize)
  end

  def corpus_search_comparison_effect_value(measure, value)
    return "—" if value.blank?

    number = Float(value)
    return "—" unless number.finite?

    case measure.to_s
    when "document_prevalence_difference_percentage_points"
      number_to_percentage(number, precision: 2)
    when "poisson_log_likelihood_p_value"
      number < 0.0001 ? format("%.3e", number) : number_with_precision(number, precision: 4, strip_insignificant_zeros: true)
    when "poisson_log_likelihood_g2"
      number_with_precision(number, precision: 3, strip_insignificant_zeros: true)
    else
      number_with_precision(number, precision: 4, strip_insignificant_zeros: true)
    end
  rescue ArgumentError, TypeError
    "—"
  end

  def corpus_search_folder_checkbox_id(path, scope)
    digest = Digest::SHA256.hexdigest(path.to_s).first(12)
    "corpus-search-folder-#{scope}-#{digest}"
  end

  def corpus_search_folder_branch_open?(node, query)
    selected = query.include_folders + query.exclude_folders
    path = node["path"].to_s
    selected.any? { |candidate| candidate == path || candidate.start_with?("#{path}/") }
  end

  def corpus_search_folder_role_summary(node)
    counts = node.fetch("role_counts", {})
    CorpusSearch::DocumentRole::SEARCHABLE_ROLES.filter_map do |role|
      count = counts[role].to_i
      next if count.zero?

      "#{t("corpus_search.roles.#{role}")}: #{number_with_delimiter(count)}"
    end.join("; ")
  end

  private

  def corpus_search_folder_node(node, query, level)
    path = node.fetch("path")
    children = Array(node["children"])
    branch_open = corpus_search_folder_branch_open?(node, query)
    include_id = corpus_search_folder_checkbox_id(path, "include")
    exclude_id = corpus_search_folder_checkbox_id(path, "exclude")

    row = tag.div(class: "corpus-search-folder-node-row") do
      safe_join([
        corpus_search_folder_toggle(node, children, branch_open),
        corpus_search_folder_include_choice(node, query, path, include_id),
        corpus_search_folder_exclude_choice(node, query, path, exclude_id)
      ])
    end

    branch = if children.any?
      tag.div(
        safe_join(children.map { |child| corpus_search_folder_node(child, query, level + 1) }),
        class: "corpus-search-folder-children",
        role: "group",
        hidden: !branch_open,
        data: { corpus_search_folder_children: true }
      )
    end

    tag.div(
      safe_join([row, branch].compact),
      class: "corpus-search-folder-node",
      role: "treeitem",
      aria: { expanded: branch_open },
      style: "--corpus-folder-depth: #{level}",
      data: {
        corpus_search_folder_node: true,
        folder_search_text: [node["name"], path].join(" ").downcase
      }
    )
  end

  def corpus_search_folder_toggle(node, children, branch_open)
    return tag.span("", class: "corpus-search-folder-toggle-spacer", aria: { hidden: true }) if children.empty?

    tag.button(
      tag.span("▸", aria: { hidden: true }),
      type: "button",
      class: "corpus-search-folder-toggle",
      aria: {
        expanded: branch_open,
        label: t("corpus_search.actions.toggle_folder", folder: node["name"])
      },
      data: { action: "corpus-search-form#toggleFolderBranch" }
    )
  end

  def corpus_search_folder_include_choice(node, query, path, input_id)
    tag.label(class: "corpus-search-folder-choice", for: input_id, title: path) do
      safe_join([
        check_box_tag(
          "folders[]",
          path,
          query.include_folders.include?(path),
          id: input_id,
          data: {
            corpus_search_form_target: "folderChoice",
            corpus_folder_path: path,
            corpus_folder_scope: "include",
            action: "corpus-search-form#selectFolder"
          }
        ),
        tag.span(node["name"], class: "corpus-search-folder-name"),
        tag.span(
          number_with_delimiter(node["document_count"].to_i),
          class: "corpus-search-folder-count",
          title: corpus_search_folder_role_summary(node)
        )
      ])
    end
  end

  def corpus_search_folder_exclude_choice(node, query, path, input_id)
    tag.label(
      class: "corpus-search-folder-exclude-choice",
      for: input_id,
      title: t("corpus_search.form.exclude_named_folder", folder: node["name"])
    ) do
      safe_join([
        check_box_tag(
          "exclude_folders[]",
          path,
          query.exclude_folders.include?(path),
          id: input_id,
          data: {
            corpus_search_form_target: "folderChoice",
            corpus_folder_path: path,
            corpus_folder_scope: "exclude",
            action: "corpus-search-form#selectFolder"
          }
        ),
        tag.span(t("corpus_search.form.exclude_folder"))
      ])
    end
  end

  def highlighted_ranges(hit)
    term_matches = Array(hit["term_matches"])
    return [[hit["start_offset"], hit["end_offset"]]] if term_matches.empty?

    term_matches.map { |match| [match["start_offset"], match["end_offset"]] }
  end

  def merge_ranges(ranges)
    ranges.sort_by(&:first).each_with_object([]) do |range, merged|
      if merged.empty? || range.first > merged.last.last
        merged << range.dup
      else
        merged.last[1] = [merged.last.last, range.last].max
      end
    end
  end

  def render_highlighted_text(text, ranges)
    chars = text.each_char.to_a
    cursor = 0
    fragments = []

    ranges.each do |range_start, range_end|
      fragments << ERB::Util.html_escape(chars[cursor...range_start].to_a.join)
      fragments << content_tag(:mark, chars[range_start...range_end].to_a.join)
      cursor = range_end
    end

    fragments << ERB::Util.html_escape(chars[cursor..].to_a.join)
    safe_join(fragments)
  end
end
