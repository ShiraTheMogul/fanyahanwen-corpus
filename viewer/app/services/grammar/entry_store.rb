# frozen_string_literal: true

require "digest"
require "fileutils"
require "pathname"
require "tempfile"
require "yaml"

module Grammar
  class EntryStore
    ROOT = Rails.root.join("content", "grammar")
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
      def published?
        document.present?
      end

      def translated?
        published? && locale.to_s != Grammar::EntryStore::SOURCE_LOCALE
      end

      def raw
        document&.raw.to_s
      end

      def metadata
        document&.metadata || {}
      end

      def body
        document&.body.to_s
      end
    end

    attr_reader :root

    def self.default
      new
    end

    def initialize(root: ROOT)
      @root = Pathname.new(root)
    end

    def all
      entries
    end

    def find(id)
      entries_by_id[id.to_s]
    end

    def find!(id)
      find(id) || raise(ActiveRecord::RecordNotFound, "Unknown grammar entry")
    end

    def children_for(parent_id)
      entries.select { |entry| entry.parent_id == parent_id.to_s }
    end

    def related_for(entry, metadata: nil)
      metadata = MarkdownDocument.stringify_keys(metadata.to_h)
      ids = entry.related_ids + entry.comparison_ids
      ids += Array(metadata["related"]).map(&:to_s)
      ids += Array(metadata["comparisons"]).map(&:to_s)
      ids.uniq.filter_map { |id| find(id) }
    end

    def load(entry_or_id, locale: I18n.locale)
      entry = entry_or_id.is_a?(Entry) ? entry_or_id : find!(entry_or_id)
      requested = normalise_locale(locale)
      requested_path = article_path(entry, locale: requested)
      canonical_path = article_path(entry, locale: SOURCE_LOCALE)

      path =
        if requested != SOURCE_LOCALE && requested_path.file?
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

      raw = path.binread.force_encoding("UTF-8").scrub
      LoadedEntry.new(
        entry: entry,
        document: MarkdownDocument.parse(raw),
        requested_locale: requested,
        locale: locale_for_path(entry, path),
        path: path,
        fallback: requested != SOURCE_LOCALE && path == canonical_path,
        revision: Digest::SHA256.hexdigest(raw)[0, 12]
      )
    end

    def article_exists?(entry_or_id, locale: SOURCE_LOCALE)
      entry = entry_or_id.is_a?(Entry) ? entry_or_id : find!(entry_or_id)
      article_path(entry, locale: locale).file?
    end

    def article_path(entry_or_id, locale: SOURCE_LOCALE)
      entry = entry_or_id.is_a?(Entry) ? entry_or_id : find!(entry_or_id)
      canonical = safe_path(entry.path)
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

      if article_exists?(entry, locale: locale)
        load(entry, locale: locale).document.without_publication_metadata
      else
        template_for(entry, locale: locale)
      end
    end

    def template_for(entry_or_id, locale: SOURCE_LOCALE)
      entry = entry_or_id.is_a?(Entry) ? entry_or_id : find!(entry_or_id)
      body = template_body_for(entry.kind)

      metadata = {
        "id" => entry.id,
        "kind" => entry.kind,
        "headword" => entry.headword,
        "title" => entry.title
      }
      metadata["parent"] = entry.parent_id if entry.parent_id
      metadata["locale"] = normalise_locale(locale) unless normalise_locale(locale) == SOURCE_LOCALE

      MarkdownDocument.dump(metadata: metadata, body: body)
    end

    def template_body_for(kind)
      template_path = root.join("_templates", "#{kind}.md")
      template_path = root.join("_templates", "concept.md") unless template_path.file?
      template_path.file? ? template_path.read : "## Explanation\n\n\n## References\n\n"
    end

    # Appends one reviewed entry without reserialising the existing catalogue.
    # This preserves its current order and formatting.
    def append_catalogue_entry!(entry_or_attributes)
      entry = entry_or_attributes.is_a?(Entry) ? entry_or_attributes : Entry.new(entry_or_attributes)
      raise ArgumentError, "Duplicate grammar ID: #{entry.id}" if find(entry.id)
      raise ArgumentError, "Duplicate grammar path: #{entry.path}" if all.any? { |item| item.path == entry.path }
      raise ArgumentError, "Unknown grammar kind: #{entry.kind}" unless Entry::KINDS.include?(entry.kind)
      if entry.parent_id && !find(entry.parent_id)
        raise ArgumentError, "Unknown parent #{entry.parent_id}"
      end
      safe_path(entry.path)

      original = catalogue_path.binread.force_encoding("UTF-8").scrub
      row = YAML.dump([entry.attributes.compact]).sub(/\A---\s*\n/, "")
      replacement = original + (original.end_with?("\n") ? "" : "\n") + row

      Tempfile.create(["grammar-catalogue", ".yml"], catalogue_path.dirname.to_s) do |file|
        file.binmode
        file.write(replacement)
        file.flush
        file.fsync
        FileUtils.mv(file.path, catalogue_path)
      end

      @entries = nil
      entry
    end

    def validate_catalogue!
      ids = entries.map(&:id)
      duplicate_ids = ids.group_by(&:itself).select { |_id, values| values.length > 1 }.keys
      raise ArgumentError, "Duplicate grammar IDs: #{duplicate_ids.join(', ')}" if duplicate_ids.any?

      paths = entries.map(&:path)
      duplicate_paths = paths.group_by(&:itself).select { |_path, values| values.length > 1 }.keys
      raise ArgumentError, "Duplicate grammar paths: #{duplicate_paths.join(', ')}" if duplicate_paths.any?

      entries.each do |entry|
        raise ArgumentError, "Unknown grammar kind for #{entry.id}: #{entry.kind}" unless Entry::KINDS.include?(entry.kind)
        raise ArgumentError, "Invalid grammar ID: #{entry.id}" unless entry.id.match?(/\A[a-z0-9][a-z0-9-]*\z/)
        if entry.importance.present? && !Entry::IMPORTANCE.include?(entry.importance)
          raise ArgumentError, "Unknown importance for #{entry.id}: #{entry.importance}"
        end
        CorpusSearchDefinition.normalize_all(entry.attributes["corpus_searches"])
        safe_path(entry.path)
        if entry.parent_id && !ids.include?(entry.parent_id)
          raise ArgumentError, "Unknown parent #{entry.parent_id} for #{entry.id}"
        end
        unknown_links = (entry.related_ids + entry.comparison_ids).uniq - ids
        raise ArgumentError, "Unknown links for #{entry.id}: #{unknown_links.join(', ')}" if unknown_links.any?
      end

      true
    end

    def existing_ids
      entries.map(&:id)
    end

    private

    def catalogue_path
      root.join("catalogue.yml")
    end

    def entries
      return load_entries if Rails.env.development?

      @entries ||= load_entries
    end

    def entries_by_id
      entries.index_by(&:id)
    end

    def load_entries
      raw = YAML.safe_load(catalogue_path.read, permitted_classes: [], permitted_symbols: [], aliases: false)
      rows = raw.is_a?(Hash) ? raw.fetch("entries", []) : []
      rows.map do |attributes|
        raise ArgumentError, "Each grammar catalogue entry must be a mapping" unless attributes.is_a?(Hash)

        Entry.new(attributes)
      end
    end

    def safe_path(relative)
      relative = relative.to_s.sub(%r{\A/+}, "")
      raise SecurityError, "Grammar article path must end in .md" unless relative.end_with?(".md")

      absolute = root.join(relative).cleanpath
      unless absolute.to_s.start_with?(root.expand_path.to_s + File::SEPARATOR)
        raise SecurityError, "Grammar article path escapes content/grammar"
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
      allowed = I18n.available_locales.map(&:to_s)
      allowed.include?(candidate) ? candidate : SOURCE_LOCALE
    end
  end
end
