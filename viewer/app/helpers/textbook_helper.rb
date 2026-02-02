module TextbookHelper
  # Render a block from a lesson YAML.
  # Blocks are simple hashes with a `type` field (e.g., "context", "text", "noticing").
  def render_textbook_block(block, lesson:)
    type = block.fetch("type").to_s
    partial = "textbook/blocks/#{type}"
    render partial: partial, locals: { block: block, lesson: lesson }
  end

  # Option 1 diagram workflow: paste tab-separated values (from Google Sheets) and render an HTML table.
  # This is intentionally simple; merged cells can be supported later with HTML clipboard capture.
  def grid_from_tsv(tsv)
    rows = tsv.to_s.split(/\r?\n/).reject(&:empty?).map { |line| line.split("\t", -1) }
    return "" if rows.empty?

    content_tag(:table, class: "textbook-grid") do
      safe_join(rows.map { |cells|
        content_tag(:tr) do
          safe_join(cells.map { |cell| content_tag(:td, cell.presence || "\u00a0") })
        end
      })
    end
  end
end
