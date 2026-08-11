# frozen_string_literal: true

require "uri"

module ChengyuData
  class CharacterMemberships
    Row = Struct.new(
      :chengyu,
      :matching_form,
      :languages,
      :sense,
      :sources,
      :corpus_search_url,
      :corpus_contexts,
      keyword_init: true
    )

    attr_reader :count

    def initialize(character, limit: nil)
      @character = character
      @limit = limit.nil? ? nil : Integer(limit)
      @count = 0
      @rows = nil
    end

    def rows
      return @rows if @rows
      return @rows = [] unless @character&.id

      membership = ChengyuFormCharacter
        .where(character_codepoint_id: @character.id)
        .joins(chengyu_form: :chengyu)

      @count = membership.distinct.count("chengyu_forms.chengyu_id")
      return @rows = [] if @count.zero?

      family_scope = Chengyu
        .where(id: membership.select("chengyu_forms.chengyu_id"))
        .order(:display_form, :id)
      family_scope = family_scope.limit(@limit) if @limit
      family_ids = family_scope.pluck(:id)

      family_includes = [:forms, :attestations, :senses]
      if defined?(ChengyuCorpusOccurrence) && ChengyuCorpusOccurrence.table_exists?
        family_includes << :corpus_occurrences
      end

      families = Chengyu
        .where(id: family_ids)
        .includes(*family_includes)
        .index_by(&:id)

      matching_forms = ChengyuForm
        .where(chengyu_id: family_ids)
        .joins(:form_characters)
        .where(chengyu_form_characters: { character_codepoint_id: @character.id })
        .distinct
        .to_a
        .group_by(&:chengyu_id)

      @rows = family_ids.filter_map do |family_id|
        family = families[family_id]
        next unless family

        candidates = matching_forms[family_id] || []
        matching = candidates.find(&:is_display_form?) || candidates.sort_by(&:form_text).first
        languages = family.attestations.map(&:entry_language_tag).compact.uniq
        sense = preferred_sense(family.senses)
        sources = family.attestations
          .uniq { |attestation| [attestation.site, attestation.pageid] }
          .first(3)
        search_text = matching&.form_text.presence || family.display_form

        Row.new(
          chengyu: family,
          matching_form: matching,
          languages: languages,
          sense: sense,
          sources: sources,
          corpus_search_url: corpus_search_url(search_text),
          corpus_contexts: corpus_contexts(family)
        )
      end
    end

    private

    def preferred_sense(senses)
      senses.min_by do |sense|
        [sense.definition_language_tag.to_s == "en" ? 0 : 1, sense.definition_language_tag.to_s, sense.id]
      end
    end

    def corpus_search_url(text)
      "/corpus/search?#{URI.encode_www_form([["mode", "exact"], ["q", text.to_s]])}"
    end

    def corpus_contexts(family)
      return [] unless defined?(ChengyuCorpusOccurrence) && ChengyuCorpusOccurrence.table_exists?

      family.corpus_occurrences
        .sort_by { |occurrence| [occurrence.document_path.to_s, occurrence.start_offset.to_i, occurrence.id.to_i] }
        .uniq { |occurrence| [occurrence.document_path, occurrence.start_offset, occurrence.end_offset] }
        .first(3)
        .map do |occurrence|
          {
            label: occurrence.context_label,
            url: Rails.application.routes.url_helpers.corpus_viewer_path(
              occurrence.document_path.split("/"),
              format: nil,
              anchor: occurrence.anchor_id
            )
          }
        end
    rescue ActiveRecord::StatementInvalid
      []
    end
  end
end
