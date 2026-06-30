# frozen_string_literal: true

require "pathname"

module Grammar
  # Builds a safe catalogue entry for an article topic that is not listed yet.
  # The submitter supplies descriptive fields; IDs and file paths are derived.
  class ProposedEntryBuilder
    class ValidationError < StandardError; end

    COLLECTIONS = {
      "pattern" => "patterns",
      "binome" => "binomes",
      "comparison" => "comparisons",
      "concept" => "concepts"
    }.freeze

    def initialize(store: EntryStore.default)
      @store = store
    end

    def build!(kind:, headword:, title: nil, parent_id: nil, label: nil)
      kind = kind.to_s
      raise ValidationError, "Unknown grammar entry type" unless Entry::KINDS.include?(kind)

      headword = headword.to_s.strip
      title = title.to_s.strip.presence || headword
      raise ValidationError, "Headword is required" if headword.blank?
      raise ValidationError, "Article title is required" if title.blank?

      parent = nil
      if kind == "function"
        parent_id = parent_id.to_s.strip
        label = label.to_s.strip
        raise ValidationError, "Choose the parent function-word entry" if parent_id.blank?
        raise ValidationError, "Add a short function label" if label.blank?

        parent = @store.find(parent_id)
        raise ValidationError, "Unknown parent grammar entry" if parent.nil?
        unless parent.kind == "function_word"
          raise ValidationError, "An individual function must belong to a function-word entry"
        end
      else
        parent_id = nil
        label = nil
      end

      id = Identifier.generate(kind: kind, headword: headword, parent_id: parent_id, label: label)
      if Identifier.collision?(id, @store.existing_ids)
        raise ValidationError, "This entry already exists; open the existing page instead"
      end

      path = proposed_path(kind: kind, headword: headword, title: title, parent: parent, label: label, id: id)
      if @store.all.any? { |entry| entry.path == path }
        raise ValidationError, "Another grammar entry already uses the proposed article path"
      end

      Entry.new({
        "id" => id,
        "kind" => kind,
        "headword" => headword,
        "title" => title,
        "path" => path,
        "parent" => parent_id
      }.compact)
    end

    private

    def proposed_path(kind:, headword:, title:, parent:, label:, id:)
      case kind
      when "function_word"
        "function_words/#{safe_filename(headword)}/index.md"
      when "function"
        filename = ascii_filename(label).presence || id.delete_prefix("#{parent.id}-")
        Pathname.new(parent.path).dirname.join("functions", "#{filename}.md").to_s
      else
        collection = COLLECTIONS.fetch(kind)
        source = kind == "concept" ? title : headword
        "#{collection}/#{safe_filename(source)}.md"
      end
    end

    def safe_filename(value)
      filename = value.to_s.strip
                      .gsub(/[<>:\"\/\\|?*\u0000-\u001f]/, "-")
                      .gsub(/\s+/, "-")
                      .gsub(/-+/, "-")
                      .gsub(/\A[. -]+|[. -]+\z/, "")
      if filename.blank? || %w[. ..].include?(filename)
        raise ValidationError, "The entry name cannot be used as a safe filename"
      end

      filename
    end

    def ascii_filename(value)
      value.to_s
           .downcase
           .encode("ASCII", invalid: :replace, undef: :replace, replace: " ")
           .gsub(/[^a-z0-9]+/, "_")
           .gsub(/\A_+|_+\z/, "")
    end
  end
end
