# frozen_string_literal: true

require "fileutils"
require "tempfile"

module Atlas
  class Publisher
    def initialize(store: EntryStore.default, reviewer_name: nil, today: Date.current)
      @store = store
      @reviewer_name = reviewer_name.to_s.strip
      @today = today
    end

    def publish!(entry_id:, locale:, proposed_markdown:, credit:)
      entry = @store.find!(entry_id)
      target = @store.article_path(entry, locale: locale)
      proposed = Grammar::MarkdownDocument.parse(proposed_markdown)
      existing = target.file? ? Grammar::MarkdownDocument.parse(target.read) : nil

      metadata = proposed.metadata.dup
      metadata["contributors"] = merge_contributors(Array(existing&.metadata&.dig("contributors")), credit)
      metadata["licence"] = "CC BY"
      metadata["published_at"] = existing&.metadata&.dig("published_at") || @today.iso8601
      metadata["updated_at"] = @today.iso8601

      if locale.to_s != EntryStore::SOURCE_LOCALE
        canonical = @store.load(entry, locale: EntryStore::SOURCE_LOCALE)
        metadata["translation_of"] = entry.id
        original_date = canonical.metadata["published_at"]
        metadata["original_published_at"] = original_date if original_date.present?
      else
        metadata.delete("translation_of")
        metadata.delete("original_published_at")
      end

      final_markdown = Grammar::MarkdownDocument.dump(metadata: metadata, body: proposed.body)
      atomic_write(target, final_markdown)
      final_markdown
    end

    private

    def merge_contributors(existing, credit)
      rows = Array(existing).filter_map do |item|
        item.is_a?(Hash) ? Grammar::MarkdownDocument.stringify_keys(item) : nil
      end
      public_credit = Grammar::MarkdownDocument.stringify_keys(credit.to_h)
      if public_credit["role"].present? && public_credit["role"] != "anonymous"
        rows << public_credit.merge("date" => @today.iso8601)
      end
      if @reviewer_name.present?
        rows << { "name" => @reviewer_name, "role" => "editor", "date" => @today.iso8601 }
      end
      rows.uniq { |row| [row["name"], row["orcid"], row["role"], row["date"]] }
    end

    def atomic_write(path, content)
      FileUtils.mkdir_p(path.dirname)
      Tempfile.create(["atlas-entry", ".md"], path.dirname.to_s) do |file|
        file.binmode
        file.write(content)
        file.flush
        file.fsync
        FileUtils.mv(file.path, path)
      end
    end
  end
end
