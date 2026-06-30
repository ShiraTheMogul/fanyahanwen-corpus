# frozen_string_literal: true

require "cgi"
require "digest"
require "erb"
require "rdoc"
require "rdoc/markdown"
require "rdoc/markup/to_html"

module Grammar
  class MarkdownRenderer
    COLLAPSIBLE_HEADINGS = [
      "technical explanation",
      "technical note",
      "technical analysis",
      "術語詳解",
      "技術說明"
    ].freeze

    REFERENCE_HEADINGS = MarkdownDocument::REFERENCE_HEADINGS.freeze
    DIRECTIVE = /\{%\s*corpus_quote\s+(.*?)\s*%\}/m.freeze
    ATTRIBUTE = /([a-z_]+)="([^"]*)"/i.freeze

    def self.render(document_or_body)
      document =
        if document_or_body.is_a?(MarkdownDocument)
          document_or_body
        else
          MarkdownDocument.parse(document_or_body.to_s)
        end

      new(document).render
    end

    def initialize(document)
      @document = document
      @tokens = {}
    end

    def render
      protected_body = protect_directives(@document.body)
      sections = split_sections(protected_body)

      html = sections.map do |section|
        render_section(section[:heading], section[:body])
      end.join("\n")

      restore_directives(html)
    end

    private

    def split_sections(body)
      sections = [{ heading: nil, body: +"" }]

      body.each_line do |line|
        match = line.match(/\A##\s+(.+?)\s*#*\s*\z/)
        if match
          sections << { heading: match[1].strip, body: +"" }
        else
          sections.last[:body] << line
        end
      end

      sections.reject { |section| section[:heading].nil? && section[:body].strip.blank? }
    end

    def render_section(heading, body)
      rendered = render_markdown(body)
      return rendered if heading.nil?

      normalized = normalise_heading(heading)
      id = heading_id(heading)

      if collapsible_heading?(normalized)
        <<~HTML
          <details class="grammar-technical" id="#{id}">
            <summary>#{CGI.escapeHTML(heading)}</summary>
            <div class="grammar-section-body">#{rendered}</div>
          </details>
        HTML
      else
        css = REFERENCE_HEADINGS.include?(normalized) ? " grammar-references" : ""
        <<~HTML
          <section class="grammar-article-section#{css}" id="#{id}">
            <h2>#{CGI.escapeHTML(heading)}</h2>
            <div class="grammar-section-body">#{rendered}</div>
          </section>
        HTML
      end
    end

    def render_markdown(markdown)
      return "" if markdown.to_s.strip.blank?

      options = RDoc::Options.new
      html = RDoc::Markup::ToHtml.new(options).convert(RDoc::Markdown.parse(markdown))
      html.gsub(%r{<span><a href="#label-[^"]+">&para;</a>\s*<a href="#top">&uarr;</a></span>}, "")
    end

    def protect_directives(body)
      body.gsub(DIRECTIVE) do
        token = "GRAMMARQUOTE#{@tokens.length}TOKEN"
        @tokens[token] = corpus_quote_html(Regexp.last_match(1))
        "\n\n#{token}\n\n"
      end
    end

    def restore_directives(html)
      @tokens.reduce(html) do |output, (token, replacement)|
        output.gsub("<p>#{token}</p>", replacement).gsub(token, replacement)
      end
    end

    def corpus_quote_html(raw_attributes)
      attributes = raw_attributes.scan(ATTRIBUTE).to_h
      text = attributes["text"].to_s
      path = attributes["path"].to_s
      highlight = attributes["highlight"].to_s
      source = attributes["source"].to_s

      escaped_text = CGI.escapeHTML(text)
      highlight.split("|").map(&:strip).reject(&:blank?).sort_by { |term| -term.length }.each do |term|
        escaped = CGI.escapeHTML(term)
        escaped_text = escaped_text.gsub(escaped, "<mark>#{escaped}</mark>")
      end

      source_label = source.presence || File.basename(path, File.extname(path))
      link = path.present? ? "/corpus_viewer/#{escape_path(path)}" : nil
      footer =
        if link
          %(<a href="#{CGI.escapeHTML(link)}">#{CGI.escapeHTML(source_label)}</a>)
        elsif source_label.present?
          CGI.escapeHTML(source_label)
        end

      <<~HTML
        <figure class="grammar-corpus-quote">
          <blockquote>#{escaped_text}</blockquote>
          #{footer.present? ? "<figcaption>#{footer}</figcaption>" : ""}
        </figure>
      HTML
    end

    def escape_path(path)
      path.to_s.split("/").map { |segment| ERB::Util.url_encode(segment) }.join("/")
    end

    def collapsible_heading?(normalized)
      configured = Array(@document.metadata["collapsible_sections"]).map { |value| normalise_heading(value) }
      COLLAPSIBLE_HEADINGS.include?(normalized) || configured.include?(normalized)
    end

    def heading_id(value)
      ascii = value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      return ascii if ascii.present?

      "section-#{Digest::SHA256.hexdigest(value.to_s)[0, 8]}"
    end

    def normalise_heading(value)
      value.to_s.downcase.strip.gsub(/[：:]\z/, "")
    end
  end
end
