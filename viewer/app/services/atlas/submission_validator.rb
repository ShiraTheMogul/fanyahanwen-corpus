# frozen_string_literal: true

module Atlas
  class SubmissionValidator
    class ValidationError < StandardError; end

    ACTIONS = %w[create edit translate].freeze
    SOURCE_AUTHORED_KEYS = %w[title corpus_searches related collapsible_sections].freeze
    TRANSLATION_AUTHORED_KEYS = %w[title collapsible_sections].freeze
    ROLES = {
      "create" => %w[author anonymous],
      "edit" => %w[contributor anonymous],
      "translate" => %w[translator anonymous]
    }.freeze

    Result = Struct.new(
      :entry, :action, :locale, :document, :markdown, :credit, :target_path,
      keyword_init: true
    )

    def initialize(store: EntryStore.default)
      @store = store
    end

    def validate!(entry_id:, action:, locale:, raw_markdown:, public_name:, orcid:, credit_role:, licence_agreed:)
      entry = @store.find!(entry_id)
      action = action.to_s
      raise ValidationError, "Invalid atlas submission action" unless ACTIONS.include?(action)

      locale = normalise_locale(locale)
      target = @store.article_path(entry, locale: locale)
      validate_action_target!(entry, action, locale, target)
      raise ValidationError, "You must agree to publish the submission under CC BY" unless truthy?(licence_agreed)

      document = Grammar::MarkdownDocument.parse(raw_markdown)
      raise ValidationError, "The article body is empty" if document.body.strip.blank?
      raise ValidationError, "Add a distinct References section before submitting" unless document.references_heading?

      role = credit_role.to_s
      raise ValidationError, "Invalid public credit role" unless ROLES.fetch(action).include?(role)

      name = public_name.to_s.strip
      if role != "anonymous" && name.blank?
        raise ValidationError, "A public name or pseudonym is required unless you choose anonymous credit"
      end

      normalized_orcid = Grammar::Orcid.normalize(orcid)
      raise ValidationError, "An anonymous submission cannot publish an ORCID" if role == "anonymous" && normalized_orcid.present?

      submitted = document.metadata.reject do |key, _|
        Grammar::MarkdownDocument::PUBLICATION_KEYS.include?(key.to_s)
      end
      metadata = if locale == EntryStore::SOURCE_LOCALE
                   submitted.slice(*SOURCE_AUTHORED_KEYS)
                 else
                   submitted.slice(*TRANSLATION_AUTHORED_KEYS)
                 end

      validate_related!(metadata, entry)
      if metadata.key?("corpus_searches")
        metadata["corpus_searches"] = Grammar::CorpusSearchDefinition.normalize_all(metadata["corpus_searches"])
      end

      metadata["id"] = entry.id
      metadata["kind"] = entry.kind
      metadata["title"] = submitted["title"].presence || entry.title
      metadata["hanzi"] = entry.hanzi
      locale == EntryStore::SOURCE_LOCALE ? metadata.delete("locale") : metadata["locale"] = locale

      normalized = Grammar::MarkdownDocument.dump(metadata: metadata, body: document.body)
      credit = { "name" => name.presence, "orcid" => normalized_orcid, "role" => role }.compact

      Result.new(
        entry: entry,
        action: action,
        locale: locale,
        document: Grammar::MarkdownDocument.parse(normalized),
        markdown: normalized,
        credit: credit,
        target_path: target
      )
    rescue Psych::SyntaxError, ArgumentError => e
      raise ValidationError, e.message
    rescue ActiveRecord::RecordNotFound
      raise ValidationError, "Unknown atlas entry"
    end

    private

    def validate_action_target!(entry, action, locale, target)
      case action
      when "create"
        raise ValidationError, "This article already exists; suggest an edit instead" if target.file?
        raise ValidationError, "Use a translation submission for a non-source locale" if locale != EntryStore::SOURCE_LOCALE
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

    def validate_related!(metadata, entry)
      return unless metadata.key?("related")

      ids = Array(metadata["related"]).map(&:to_s).reject(&:blank?).uniq
      unknown = ids.reject { |id| @store.find(id) }
      raise ValidationError, "Unknown atlas entry IDs in related: #{unknown.join(', ')}" if unknown.any?
      raise ValidationError, "An atlas entry cannot link to itself" if ids.include?(entry.id)
      metadata["related"] = ids
    end

    def normalise_locale(value)
      candidate = value.to_s
      raise ValidationError, "Unknown article language" unless I18n.available_locales.map(&:to_s).include?(candidate)
      candidate
    end

    def truthy?(value)
      value == true || %w[1 true yes on].include?(value.to_s.downcase)
    end
  end
end
