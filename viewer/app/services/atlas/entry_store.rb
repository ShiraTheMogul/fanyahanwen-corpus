# frozen_string_literal: true

require "digest"
require "pathname"

module Atlas
  class EntryStore
    ROOT = Rails.root.join("content", "atlas")
    SOURCE_LOCALE = "en"

    LoadedEntry = Struct.new(
      :entry,
      :document,
      :requested_locale,
      :locale,
      :path,
      :fallback,
      :revision,
      keyword_init: true
    ) do
      def published? = document.present?
      def translated? = published? && locale.to_s != Atlas::EntryStore::SOURCE_LOCALE
      def raw = document&.raw.to_s
      def metadata = document&.metadata || {}
      def body = document&.body.to_s
    end

    def self.default
      @default ||= new
    end

    def self.reset!
      @default = nil
    end

    attr_reader :root, :catalogue

    def initialize(root: ROOT, catalogue: Catalogue.default)
      @root = Pathname.new(root)
      @catalogue = catalogue
    end

    def all = catalogue.entries
    def find(id) = catalogue.find(id)
    def find!(id) = catalogue.find!(id)

    def related_for(entry, metadata: nil)
      metadata = Grammar::MarkdownDocument.stringify_keys(metadata.to_h)
      ids = entry.related_ids + Array(metadata["related"]).map(&:to_s)
      ids.uniq.filter_map { |id| find(id) }
    end

    def load(entry_or_id, locale: I18n.locale)
      entry = entry_or_id.is_a?(Entry) ? entry_or_id : find!(entry_or_id)
      requested = normalise_locale(locale)
      requested_path = article_path(entry, locale: requested)
      canonical_path = article_path(entry, locale: SOURCE_LOCALE)
      path = if requested != SOURCE_LOCALE && requested_path.file?
               requested_path
             elsif canonical_path.file?
               canonical_path
             end

      return LoadedEntry.new(
        entry: entry,
        document: nil,
        requested_locale: requested,
        locale: requested,
        path: requested_path,
        fallback: false,
        revision: nil
      ) unless path

      raw = read_utf8!(path)
      LoadedEntry.new(
        entry: entry,
        document: Grammar::MarkdownDocument.parse(raw),
        requested_locale: requested,
        locale: locale_for_path(entry, path),
        path: path,
        fallback: requested != SOURCE_LOCALE && path == canonical_path,
        revision: Digest::SHA256.hexdigest(raw)[0, 12]
      )
    end

    def article_exists?(entry_or_id, locale: SOURCE_LOCALE)
      article_path(entry_or_id, locale: locale).file?
    end

    def article_path(entry_or_id, locale: SOURCE_LOCALE)
      entry = entry_or_id.is_a?(Entry) ? entry_or_id : find!(entry_or_id)
      canonical = safe_article_path(entry.article_path)
      locale = normalise_locale(locale)
      return canonical if locale == SOURCE_LOCALE

      canonical.sub_ext(".#{locale}.md")
    end

    def repo_relative_article_path(entry_or_id, locale: SOURCE_LOCALE)
      article_path(entry_or_id, locale: locale).relative_path_from(Rails.root).to_s
    end

    def submission_markdown_for(entry_or_id, locale: SOURCE_LOCALE)
      entry = entry_or_id.is_a?(Entry) ? entry_or_id : find!(entry_or_id)
      locale = normalise_locale(locale)
      return load(entry, locale: locale).document.without_publication_metadata if article_exists?(entry, locale: locale)

      template_for(entry, locale: locale)
    end

    def template_for(entry_or_id, locale: SOURCE_LOCALE)
      entry = entry_or_id.is_a?(Entry) ? entry_or_id : find!(entry_or_id)
      metadata = {
        "id" => entry.id,
        "kind" => entry.kind,
        "title" => entry.title,
        "hanzi" => entry.hanzi
      }
      metadata["locale"] = normalise_locale(locale) unless normalise_locale(locale) == SOURCE_LOCALE
      Grammar::MarkdownDocument.dump(metadata: metadata, body: template_body)
    end

    def template_body
      path = root.join("_templates", "article.md")
      path.file? ? read_utf8!(path) : "## Overview\n\n\n## History\n\n\n## References\n\n"
    end

    def validate!
      catalogue.validate!
      all.each { |entry| safe_article_path(entry.article_path) }
      true
    end

    private

    def read_utf8!(path)
      raw = path.binread.force_encoding(Encoding::UTF_8)
      raise ArgumentError, "Atlas file is not valid UTF-8: #{path}" unless raw.valid_encoding?

      Atlas::UnicodeGuard.validate!(raw, context: path.to_s)
      raw
    end

    def safe_article_path(relative)
      relative = relative.to_s.sub(%r{\A/+}, "")
      raise SecurityError, "Atlas article path must end in .md" unless relative.end_with?(".md")

      absolute = root.join(relative).cleanpath
      unless absolute.to_s.start_with?(root.expand_path.to_s + File::SEPARATOR)
        raise SecurityError, "Atlas article path escapes content/atlas"
      end
      absolute
    end

    def locale_for_path(entry, path)
      canonical = article_path(entry, locale: SOURCE_LOCALE)
      return SOURCE_LOCALE if path == canonical

      path.basename.to_s[/\.([a-z0-9_-]+)\.md\z/, 1] || SOURCE_LOCALE
    end

    def normalise_locale(value)
      candidate = value.to_s
      I18n.available_locales.map(&:to_s).include?(candidate) ? candidate : SOURCE_LOCALE
    end
  end
end
