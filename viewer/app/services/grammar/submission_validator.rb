# frozen_string_literal: true

module Grammar
  class SubmissionValidator
    class ValidationError < StandardError; end

    ACTIONS = %w[create edit translate].freeze
    SOURCE_AUTHORED_KEYS = %w[
      title related comparisons corpus_searches collapsible_sections
    ].freeze
    TRANSLATION_AUTHORED_KEYS = %w[title collapsible_sections].freeze

    ROLES = {
      "create" => %w[author anonymous],
      "edit" => %w[contributor anonymous],
      "translate" => %w[translator anonymous]
    }.freeze

    Result = Struct.new(
      :entry,
      :action,
      :locale,
      :document,
      :markdown,
      :credit,
      :target_path,
      :catalogue_entry,
      keyword_init: true
    )

    def initialize(store: EntryStore.default)
      @store = store
    end

    def validate!(
      entry_id:,
      action:,
      locale:,
      raw_markdown:,
      public_name:,
      orcid:,
      credit_role:,
      licence_agreed:,
      entry_attributes: nil
    )
      entry = if entry_attributes.present?
                ProposedEntryBuilder.new(store: @store).build!(
                  **symbolize_entry_attributes(entry_attributes)
                )
              else
                @store.find!(entry_id)
              end
      action = action.to_s
      raise ValidationError, "Invalid grammar submission action" unless ACTIONS.include?(action)

      locale = normalise_locale(locale)
      target = @store.article_path(entry, locale: locale)
      validate_action_target!(entry, action, locale, target, unlisted: entry_attributes.present?)

      unless truthy?(licence_agreed)
        raise ValidationError, "You must agree to publish the submission under CC BY"
      end

      document = MarkdownDocument.parse(raw_markdown)
      raise ValidationError, "The article body is empty" if document.body.strip.blank?
      raise ValidationError, "Add a distinct References section before submitting" unless document.references_heading?

      role = credit_role.to_s
      raise ValidationError, "Invalid public credit role" unless ROLES.fetch(action).include?(role)

      name = public_name.to_s.strip
      if role != "anonymous" && name.blank?
        raise ValidationError, "A public name or pseudonym is required unless you choose anonymous credit"
      end

      normalized_orcid = Orcid.normalize(orcid)
      if role == "anonymous" && normalized_orcid.present?
        raise ValidationError, "An anonymous submission cannot publish an ORCID"
      end

      submitted_metadata = document.metadata.reject do |key, _|
        MarkdownDocument::PUBLICATION_KEYS.include?(key.to_s)
      end
      metadata =
        if locale == EntryStore::SOURCE_LOCALE
          submitted_metadata.slice(*SOURCE_AUTHORED_KEYS)
        else
          submitted_metadata.slice(*TRANSLATION_AUTHORED_KEYS)
        end

      validate_entry_links!(metadata, entry)
      if metadata.key?("corpus_searches")
        metadata["corpus_searches"] = CorpusSearchDefinition.normalize_all(metadata["corpus_searches"])
      end

      metadata["id"] = entry.id
      metadata["kind"] = entry.kind
      metadata["headword"] = entry.headword
      metadata["title"] = locale == EntryStore::SOURCE_LOCALE ? entry.title : submitted_metadata["title"].presence || entry.title
      entry.parent_id ? metadata["parent"] = entry.parent_id : metadata.delete("parent")
      locale == EntryStore::SOURCE_LOCALE ? metadata.delete("locale") : metadata["locale"] = locale

      normalized = MarkdownDocument.dump(metadata: metadata, body: document.body)
      credit = {
        "name" => name.presence,
        "orcid" => normalized_orcid,
        "role" => role
      }.compact

      Result.new(
        entry: entry,
        action: action,
        locale: locale,
        document: MarkdownDocument.parse(normalized),
        markdown: normalized,
        credit: credit,
        target_path: target,
        catalogue_entry: entry_attributes.present? ? entry.attributes : nil
      )
    rescue Psych::SyntaxError, ArgumentError, ProposedEntryBuilder::ValidationError => e
      raise ValidationError, e.message
    rescue ActiveRecord::RecordNotFound
      raise ValidationError, "Unknown grammar entry"
    end

    private

    def validate_action_target!(entry, action, locale, target, unlisted: false)
      if unlisted
        raise ValidationError, "An unlisted entry must be submitted as a new article" unless action == "create"
        unless locale == EntryStore::SOURCE_LOCALE
          raise ValidationError, "An unlisted entry must begin with a source-language article"
        end
      end

      case action
      when "create"
        raise ValidationError, "This article already exists; suggest an edit instead" if target.file?
        if locale != EntryStore::SOURCE_LOCALE
          raise ValidationError, "Use a translation submission for a non-source locale"
        end
      when "edit"
        raise ValidationError, "The article does not exist yet; suggest an article instead" unless target.file?
      when "translate"
        raise ValidationError, "Choose a non-source language for a translation" if locale == EntryStore::SOURCE_LOCALE
        unless @store.article_exists?(entry, locale: EntryStore::SOURCE_LOCALE)
          raise ValidationError, "The source article must be published before a translation can be submitted"
        end
        raise ValidationError, "This translation already exists; suggest an edit instead" if target.file?
      end
    end

    def validate_entry_links!(metadata, entry)
      %w[related comparisons].each do |key|
        next unless metadata.key?(key)

        ids = Array(metadata[key]).map(&:to_s).reject(&:blank?).uniq
        unknown = ids.reject { |id| @store.find(id) }
        raise ValidationError, "Unknown grammar entry IDs in #{key}: #{unknown.join(', ')}" if unknown.any?
        raise ValidationError, "A grammar entry cannot link to itself in #{key}" if ids.include?(entry.id)

        metadata[key] = ids
      end
    end

    def symbolize_entry_attributes(value)
      attributes = MarkdownDocument.stringify_keys(value.to_h)
      {
        kind: attributes["kind"],
        headword: attributes["headword"],
        title: attributes["title"],
        parent_id: attributes["parent_id"],
        label: attributes["label"]
      }
    end

    def normalise_locale(value)
      candidate = value.to_s
      allowed = I18n.available_locales.map(&:to_s)
      raise ValidationError, "Unknown article language" unless allowed.include?(candidate)

      candidate
    end

    def truthy?(value)
      value == true || %w[1 true yes on].include?(value.to_s.downcase)
    end
  end
end
