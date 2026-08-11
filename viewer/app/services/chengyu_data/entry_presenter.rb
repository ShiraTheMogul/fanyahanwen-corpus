# frozen_string_literal: true

require "uri"

module ChengyuData
  class EntryPresenter
    LANGUAGE_LABELS = {
      "zh" => "Chinese",
      "cmn" => "Mandarin",
      "yue" => "Cantonese",
      "nan" => "Hokkien",
      "ja" => "Japanese",
      "ko" => "Korean",
      "vi" => "Vietnamese"
    }.freeze

    READING_PRIORITY = %w[cmn ja ko yue nan hak wuu cdo cpx gan].freeze

    def initialize(form)
      @form = form
      @chengyu = form.chengyu
    end

    def to_h
      {
        form_id: @form.id,
        family_id: @chengyu.id,
        source_family_id: @chengyu.source_family_id,
        text: @form.form_text,
        display_form: @chengyu.display_form,
        forms: family_forms,
        first_character: @form.first_character,
        last_character: @form.last_character,
        compound: @form.compound?,
        languages: language_labels,
        readings: reading_rows,
        senses: sense_rows,
        etymologies: etymology_rows,
        sources: source_rows,
        corpus_search_url: corpus_search_url,
        corpus_contexts: corpus_context_rows
      }
    end

    private

    def family_forms
      @chengyu.forms
        .sort_by { |form| [form.is_display_form? ? 0 : 1, form.form_text] }
        .first(8)
        .map(&:form_text)
    end

    def language_labels
      tags = @chengyu.attestations.map(&:entry_language_tag).compact.uniq
      tags.map { |tag| LANGUAGE_LABELS.fetch(tag, tag) }.uniq
    end

    def reading_rows
      rows = @chengyu.readings.uniq { |row| [row.language_tag, row.system, row.reading] }
      rows.sort_by! do |row|
        priority = READING_PRIORITY.index(row.language_tag.to_s) || READING_PRIORITY.length
        [priority, row.language_label.to_s, row.system.to_s, row.reading.to_s]
      end

      rows.first(6).map do |row|
        {
          language: row.language_label.presence || LANGUAGE_LABELS.fetch(row.language_tag.to_s, row.language_tag),
          system: row.system_label.presence || row.system,
          reading: row.reading
        }
      end
    end

    def sense_rows
      preferred = @chengyu.senses.sort_by do |sense|
        language_priority = sense.definition_language_tag.to_s == "en" ? 0 : 1
        [language_priority, sense.definition_language_tag.to_s, sense.site.to_s, sense.id]
      end

      preferred.first(3).map do |sense|
        {
          language: sense.definition_language_tag,
          text: sense.plain_definition,
          site: sense.site
        }
      end
    end

    def etymology_rows
      preferred = @chengyu.etymologies
        .select { |etymology| etymology.plain_text.present? }
        .sort_by do |etymology|
          language_priority = etymology.definition_language_tag.to_s == "en" ? 0 : 1
          [language_priority, etymology.definition_language_tag.to_s, etymology.site.to_s, etymology.id]
        end

      preferred.first(2).map do |etymology|
        {
          language: etymology.definition_language_tag,
          text: etymology.plain_text,
          site: etymology.site
        }
      end
    end


    def corpus_search_url
      "/corpus/search?#{URI.encode_www_form([["mode", "exact"], ["q", @form.form_text]])}"
    end

    def corpus_context_rows
      return [] unless defined?(ChengyuCorpusOccurrence) && ChengyuCorpusOccurrence.table_exists?

      @chengyu.corpus_occurrences
        .sort_by { |occurrence| [occurrence.document_path.to_s, occurrence.start_offset.to_i, occurrence.id.to_i] }
        .uniq { |occurrence| [occurrence.document_path, occurrence.start_offset, occurrence.end_offset] }
        .first(4)
        .map do |occurrence|
          {
            label: occurrence.context_label,
            matched_text: occurrence.matched_text,
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

    def source_rows
      @chengyu.attestations
        .uniq { |attestation| [attestation.site, attestation.pageid] }
        .first(6)
        .map do |attestation|
          {
            site: attestation.site_label,
            page_title: attestation.page_title,
            url: attestation.url
          }
        end
    end
  end
end
