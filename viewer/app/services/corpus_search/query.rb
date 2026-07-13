# frozen_string_literal: true

require "json"
require "uri"

module CorpusSearch
  # Complete request state: immutable match semantics plus display options.
  class Query
    attr_reader :search_definition, :presentation_options, :locale

    def self.from_params(params = nil, locale: I18n.locale, **keyword_params)
      QueryParams.parse(params, locale: locale, **keyword_params)
    end

    def self.from_h(hash, locale: I18n.locale)
      payload = hash.to_h.stringify_keys
      definition_hash = payload.fetch("definition", payload)
      presentation_hash = payload.fetch("presentation", {})
      matching = definition_hash.fetch("matching", {})
      scope = definition_hash.fetch("scope", {})
      proximity = definition_hash.fetch("proximity", {})

      definition = SearchDefinition.new(
        mode: definition_hash["mode"],
        query_text: definition_hash["query_text"],
        terms: definition_hash["terms"],
        maximum_span: proximity["maximum_span"],
        order: proximity["order"],
        punctuation: matching["punctuation"],
        character_equivalence: matching["character_equivalence"],
        metadata_filters: definition_hash["metadata_filters"] || {},
        document_roles: scope["document_roles"],
        include_folders: scope["include_folders"],
        exclude_folders: scope["exclude_folders"],
        deduplicate_exact_bodies: scope["deduplicate_exact_bodies"]
      )

      presentation = PresentationOptions.new(
        context: presentation_hash["context"],
        page: presentation_hash["page"],
        per_page: presentation_hash["per_page"]
      )

      new(search_definition: definition, presentation_options: presentation, locale: locale, requested: true)
    end

    def initialize(search_definition:, presentation_options:, locale: I18n.locale, requested: false)
      @search_definition = search_definition
      @presentation_options = presentation_options
      @locale = normalise_locale(locale)
      @requested = !!requested
      freeze
    end

    def mode = @search_definition.mode
    def query_text = @search_definition.query_text
    def terms = @search_definition.terms
    def maximum_span = @search_definition.maximum_span
    def order = @search_definition.order
    def punctuation = @search_definition.punctuation
    def character_equivalence = @search_definition.character_equivalence
    def metadata_filters = @search_definition.metadata_filters
    def document_roles = @search_definition.document_roles
    def include_folders = @search_definition.include_folders
    def exclude_folders = @search_definition.exclude_folders
    def deduplicate_exact_bodies? = @search_definition.deduplicate_exact_bodies?
    def filters = @search_definition.manifest_filters
    def context = @presentation_options.context
    def page = @presentation_options.page
    def per_page = @presentation_options.per_page
    def requested? = @requested
    def exact? = @search_definition.exact?
    def proximity? = @search_definition.proximity?
    def alternatives? = @search_definition.alternatives?
    def multi_term? = @search_definition.multi_term?
    def ignore_punctuation? = @search_definition.ignore_punctuation?

    def term_a = exact? ? query_text : terms[0].to_s
    def term_b = proximity? ? terms[1].to_s : ""
    def distance = maximum_span

    def valid?
      errors.empty?
    end

    def errors
      list = []
      if exact?
        list << I18n.t("corpus_search.errors.enter_sequence") if normalized_units(query_text).empty?
      elsif proximity?
        list << I18n.t("corpus_search.errors.enter_two_terms") if terms.length < 2
        list << I18n.t("corpus_search.errors.too_many_terms", max: SearchDefinition::MAX_PROXIMITY_TERMS) if terms.length > SearchDefinition::MAX_PROXIMITY_TERMS
      else
        list << I18n.t("corpus_search.errors.enter_two_alternatives") if terms.length < 2
        list << I18n.t("corpus_search.errors.too_many_alternatives", max: SearchDefinition::MAX_ALTERNATIVE_TERMS) if terms.length > SearchDefinition::MAX_ALTERNATIVE_TERMS
      end

      list << I18n.t("corpus_search.errors.term_too_long", max: 80) if effective_terms.any? { |term| term.each_char.count > 80 }
      list
    end

    def effective_terms
      @search_definition.effective_terms
    end

    def to_h
      {
        "version" => 7,
        "definition" => @search_definition.to_h,
        "presentation" => @presentation_options.to_h.except("page")
      }
    end

    def cache_key
      payload = {
        "version" => 7,
        "definition" => @search_definition.to_h
      }
      CacheStore.hash_key(JSON.generate(payload))
    end

    def display_label
      if proximity?
        I18n.t(
          "corpus_search.query.proximity_label",
          terms: terms.join(" · "),
          distance: maximum_span
        )
      elsif alternatives?
        I18n.t("corpus_search.query.alternatives_label", terms: terms.join(" OR "))
      else
        query_text
      end
    end

    def canonical_params(include_presentation: true, page: nil)
      pairs = []
      pairs << ["mode", mode]

      if exact?
        pairs << ["q", query_text]
      else
        terms.each { |term| pairs << ["terms[]", term] }
        if proximity?
          pairs << ["span", maximum_span.to_s]
          pairs << ["order", order]
        end
      end

      pairs << ["punctuation", punctuation]
      pairs << ["characters", character_equivalence]
      document_roles.each { |role| pairs << ["roles[]", role] }
      include_folders.each { |folder| pairs << ["folders[]", folder] }
      exclude_folders.each { |folder| pairs << ["exclude_folders[]", folder] }
      pairs << ["deduplicate", "1"] if deduplicate_exact_bodies?
      metadata_filters.each { |key, value| pairs << [key, value] if value.present? }

      if include_presentation
        pairs << ["context", context.to_s] unless context == 20
        pairs << ["per_page", per_page.to_s] unless per_page == 20
        selected_page = page || self.page
        pairs << ["page", selected_page.to_s] if selected_page.to_i > 1
      end

      pairs
    end

    def query_string(include_presentation: true, page: nil)
      URI.encode_www_form(canonical_params(include_presentation: include_presentation, page: page))
        .gsub("%5B%5D", "[]")
    end

    def relative_url(include_presentation: true, page: nil)
      "/corpus/search?#{query_string(include_presentation: include_presentation, page: page)}"
    end

    def normalization_profile_version
      NormalizationProfile.current.version
    end

    def character_equivalence_version
      CharacterEquivalenceRegistry.version_for(character_equivalence)
    end

    private

    def normalized_units(text)
      NormalizedText.build(text, punctuation: punctuation).units
    end

    def normalise_locale(value)
      candidate = value.to_s
      I18n.available_locales.map(&:to_s).include?(candidate) ? candidate : I18n.default_locale.to_s
    end
  end
end
