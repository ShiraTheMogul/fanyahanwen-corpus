# frozen_string_literal: true

require "csv"
require "digest"
require "json"
require "pathname"
require "set"
require "time"

module ChengyuData
  class Importer
    REQUIRED_FILES = %w[
      families.csv
      forms.csv
      attestations.csv
      readings.csv
      senses.csv
      etymologies.csv
      provenances.csv
      form_relations.csv
      semantic_relations.csv
    ].freeze

    Result = Struct.new(
      :fingerprint,
      :families,
      :forms,
      :form_characters,
      :attestations,
      :readings,
      :senses,
      :etymologies,
      :provenances,
      :form_relations,
      :semantic_relations,
      :characters_created,
      keyword_init: true
    )

    def initialize(dir:, batch_size: 1_000)
      @dir = resolve_dir(dir)
      @batch_size = Integer(batch_size)
      raise ArgumentError, "batch_size must be positive" unless @batch_size.positive?
    end

    def import
      validate_files!
      fingerprint = dataset_fingerprint
      source_manifest = read_manifest
      counts = {}
      created_characters = 0

      ActiveRecord::Base.transaction do
        clear_snapshot!

        family_rows = read_csv("families.csv")
        form_rows = read_csv("forms.csv")

        codepoints = han_codepoints(form_rows)
        created_characters = ensure_character_codepoints!(codepoints)
        character_id_by_codepoint = character_id_map(codepoints)

        insert_families!(family_rows)
        family_id_by_source = Chengyu.pluck(:source_family_id, :id).to_h

        insert_forms!(form_rows, family_id_by_source, character_id_by_codepoint)
        form_id_by_source = ChengyuForm.pluck(:source_form_id, :id).to_h

        counts[:form_characters] = insert_form_characters!(form_rows, form_id_by_source, character_id_by_codepoint)
        counts[:attestations] = insert_attestations!(family_id_by_source, form_id_by_source)
        counts[:readings] = insert_readings!(family_id_by_source, form_id_by_source)
        counts[:senses] = insert_senses!(family_id_by_source, form_id_by_source)
        counts[:etymologies] = insert_etymologies!(family_id_by_source, form_id_by_source)
        counts[:provenances] = insert_provenances!(family_id_by_source, form_id_by_source)
        counts[:form_relations] = insert_form_relations!(family_id_by_source, form_id_by_source)
        counts[:semantic_relations] = insert_semantic_relations!(family_id_by_source, form_id_by_source)
        counts[:families] = family_rows.length
        counts[:forms] = form_rows.length
        counts[:characters_created] = created_characters

        import_record = ChengyuImport.find_or_initialize_by(fingerprint: fingerprint)
        import_record.update!(
          imported_at: Time.current,
          source_path: @dir.to_s,
          source_manifest: source_manifest,
          counts: counts.transform_keys(&:to_s)
        )
      end

      Result.new(
        fingerprint: fingerprint,
        families: counts.fetch(:families),
        forms: counts.fetch(:forms),
        form_characters: counts.fetch(:form_characters),
        attestations: counts.fetch(:attestations),
        readings: counts.fetch(:readings),
        senses: counts.fetch(:senses),
        etymologies: counts.fetch(:etymologies),
        provenances: counts.fetch(:provenances),
        form_relations: counts.fetch(:form_relations),
        semantic_relations: counts.fetch(:semantic_relations),
        characters_created: created_characters
      )
    end

    def preflight
      validate_files!
      {
        dir: @dir.to_s,
        fingerprint: dataset_fingerprint,
        rows: REQUIRED_FILES.to_h { |name| [name, csv_row_count(name)] }
      }
    end

    private

    def resolve_dir(dir)
      path = Pathname.new(dir.to_s).expand_path
      nested = path.join("normalized")
      path = nested if !path.join("families.csv").file? && nested.join("families.csv").file?
      path
    end

    def validate_files!
      missing = REQUIRED_FILES.reject { |name| @dir.join(name).file? }
      return if missing.empty?

      raise ArgumentError, "Missing normalized Chengyu files in #{@dir}: #{missing.join(', ')}"
    end

    def read_csv(name)
      open_csv(name) { |io| CSV.new(io, headers: true).map(&:to_h) }
    end

    def each_csv(name, &block)
      open_csv(name) do |io|
        CSV.new(io, headers: true).each(&block)
      end
    end


    def open_csv(name)
      File.open(@dir.join(name), "r:bom|utf-8") do |io|
        yield io
      end
    end

    def csv_row_count(name)
      count = 0
      each_csv(name) { count += 1 }
      count
    end

    def dataset_fingerprint
      digest = Digest::SHA256.new
      REQUIRED_FILES.each do |name|
        digest << name << "\0" << Digest::SHA256.file(@dir.join(name)).hexdigest << "\0"
      end
      digest.hexdigest
    end

    def read_manifest
      path = @dir.join("manifest.json")
      return {} unless path.file?

      JSON.parse(path.read(encoding: "UTF-8"))
    rescue JSON::ParserError
      { "warning" => "manifest.json was not valid JSON" }
    end

    def clear_snapshot!
      [
        ChengyuCorpusOccurrence,
        ChengyuSemanticRelation,
        ChengyuFormRelation,
        ChengyuProvenance,
        ChengyuEtymology,
        ChengyuSense,
        ChengyuReading,
        ChengyuAttestation,
        ChengyuFormCharacter,
        ChengyuForm,
        Chengyu
      ].each(&:delete_all)
    end

    def insert_families!(rows)
      now = Time.current
      payload = rows.map do |row|
        {
          source_family_id: required!(row, "family_id", "families.csv"),
          display_form: required!(row, "display_form", "families.csv"),
          metadata: row.except("family_id", "display_form").compact,
          created_at: now,
          updated_at: now
        }
      end
      bulk_insert(Chengyu, payload)
    end

    def insert_forms!(rows, family_ids, character_ids)
      now = Time.current
      payload = rows.map do |row|
        family_id = lookup!(family_ids, row["family_id"], "family", row["form_id"])
        han_chars = han_chars(row["form_text"])
        first_cp = han_chars.first&.ord
        last_cp = han_chars.last&.ord

        {
          chengyu_id: family_id,
          source_form_id: required!(row, "form_id", "forms.csv"),
          form_text: required!(row, "form_text", "forms.csv"),
          game_key: han_chars.join,
          is_display_form: truthy?(row["is_display_form"]),
          script_class: required!(row, "script_class", "forms.csv"),
          codepoint_length: integer!(row["codepoint_length"], "codepoint_length", row["form_id"]),
          han_character_count: integer!(row["han_character_count"], "han_character_count", row["form_id"]),
          is_strict_han: truthy?(row["is_strict_han"]),
          contains_punctuation: truthy?(row["contains_punctuation"]),
          first_character_codepoint_id: first_cp && lookup!(character_ids, first_cp, "character", row["form_id"]),
          last_character_codepoint_id: last_cp && lookup!(character_ids, last_cp, "character", row["form_id"]),
          statuses: split_pipe(row["statuses"]),
          metadata: {
            "relation_causes" => split_pipe(row["relation_causes"]),
            "evidence_types" => split_pipe(row["evidence_types"]),
            "sites" => split_pipe(row["sites"]),
            "languages" => split_pipe(row["languages"]),
            "page_attestation_count" => integer_or_nil(row["page_attestation_count"]),
            "definition_attestation_count" => integer_or_nil(row["definition_attestation_count"]),
            "relation_source_count" => integer_or_nil(row["relation_source_count"]),
            "relation_target_count" => integer_or_nil(row["relation_target_count"])
          },
          created_at: now,
          updated_at: now
        }
      end
      bulk_insert(ChengyuForm, payload)
    end

    def insert_form_characters!(rows, form_ids, character_ids)
      now = Time.current
      payload = []
      rows.each do |row|
        form_id = lookup!(form_ids, row["form_id"], "form", row["form_id"])
        row.fetch("form_text").to_s.each_char.with_index do |char, position|
          next unless han_char?(char)

          payload << {
            chengyu_form_id: form_id,
            character_codepoint_id: lookup!(character_ids, char.ord, "character", row["form_id"]),
            glyph: char,
            position: position,
            created_at: now,
            updated_at: now
          }
        end
      end
      bulk_insert(ChengyuFormCharacter, payload)
      payload.length
    end

    def insert_attestations!(family_ids, form_ids)
      insert_csv("attestations.csv", ChengyuAttestation) do |row, now|
        {
          chengyu_id: lookup!(family_ids, row["family_id"], "family", row["attestation_id"]),
          chengyu_form_id: lookup!(form_ids, row["form_id"], "form", row["attestation_id"]),
          source_attestation_id: required!(row, "attestation_id", "attestations.csv"),
          site: required!(row, "site", "attestations.csv"),
          pageid: integer!(row["pageid"], "pageid", row["attestation_id"]),
          page_title: required!(row, "page_title", "attestations.csv"),
          entry_language_tag: blank_to_nil(row["entry_language_tag"]),
          entry_language_source: blank_to_nil(row["entry_language_source"]),
          attestation_kind: blank_to_nil(row["attestation_kind"]),
          source_keys: split_pipe(row["source_keys"]),
          source_categories: split_pipe(row["source_categories"]),
          categories: split_pipe(row["categories"]),
          revision_id: integer_or_nil(row["revision_id"]),
          revision_timestamp: time_or_nil(row["revision_timestamp"]),
          revision_sha1: blank_to_nil(row["revision_sha1"]),
          url: blank_to_nil(row["url"]),
          has_definition_evidence: truthy?(row["has_definition_evidence"]),
          source_gaps: split_pipe(row["source_gaps"]),
          created_at: now,
          updated_at: now
        }
      end
    end

    def insert_readings!(family_ids, form_ids)
      insert_csv("readings.csv", ChengyuReading) do |row, now|
        {
          chengyu_id: lookup!(family_ids, row["family_id"], "family", row["reading_id"]),
          chengyu_form_id: lookup!(form_ids, row["form_id"], "form", row["reading_id"]),
          source_reading_id: required!(row, "reading_id", "readings.csv"),
          reading: required!(row, "reading", "readings.csv"),
          language_tag: blank_to_nil(row["language_tag"]),
          language_label: blank_to_nil(row["language_label"]),
          system: blank_to_nil(row["system"]),
          system_label: blank_to_nil(row["system_label"]),
          site: blank_to_nil(row["site"]),
          pageid: integer_or_nil(row["pageid"]),
          page_title: blank_to_nil(row["page_title"]),
          source_template: blank_to_nil(row["source_template"]),
          source_type_code: blank_to_nil(row["source_type_code"]),
          url: blank_to_nil(row["url"]),
          created_at: now,
          updated_at: now
        }
      end
    end

    def insert_senses!(family_ids, form_ids)
      insert_csv("senses.csv", ChengyuSense) do |row, now|
        {
          chengyu_id: lookup!(family_ids, row["family_id"], "family", row["sense_id"]),
          chengyu_form_id: lookup!(form_ids, row["form_id"], "form", row["sense_id"]),
          source_sense_id: required!(row, "sense_id", "senses.csv"),
          site: required!(row, "site", "senses.csv"),
          pageid: integer!(row["pageid"], "pageid", row["sense_id"]),
          page_title: required!(row, "page_title", "senses.csv"),
          entry_language_tag: blank_to_nil(row["entry_language_tag"]),
          definition_language_tag: blank_to_nil(row["definition_language_tag"]),
          heading_path: blank_to_nil(row["heading_path"]),
          section_kind: blank_to_nil(row["section_kind"]),
          plain_definition: required!(row, "plain_definition", "senses.csv"),
          raw_definition: blank_to_nil(row["raw_definition"]),
          created_at: now,
          updated_at: now
        }
      end
    end

    def insert_etymologies!(family_ids, form_ids)
      insert_csv("etymologies.csv", ChengyuEtymology) do |row, now|
        {
          chengyu_id: lookup!(family_ids, row["family_id"], "family", row["etymology_id"]),
          chengyu_form_id: lookup!(form_ids, row["form_id"], "form", row["etymology_id"]),
          source_etymology_id: required!(row, "etymology_id", "etymologies.csv"),
          site: required!(row, "site", "etymologies.csv"),
          pageid: integer!(row["pageid"], "pageid", row["etymology_id"]),
          page_title: required!(row, "page_title", "etymologies.csv"),
          entry_language_tag: blank_to_nil(row["entry_language_tag"]),
          definition_language_tag: blank_to_nil(row["definition_language_tag"]),
          heading_path: blank_to_nil(row["heading_path"]),
          plain_text: blank_to_nil(row["plain_text"]),
          raw_wikitext: blank_to_nil(row["raw_wikitext"]),
          created_at: now,
          updated_at: now
        }
      end
    end

    def insert_provenances!(family_ids, form_ids)
      insert_csv("provenances.csv", ChengyuProvenance) do |row, now|
        {
          chengyu_id: lookup!(family_ids, row["family_id"], "family", row["provenance_id"]),
          chengyu_form_id: lookup!(form_ids, row["form_id"], "form", row["provenance_id"]),
          source_provenance_id: required!(row, "provenance_id", "provenances.csv"),
          site: required!(row, "site", "provenances.csv"),
          pageid: integer!(row["pageid"], "pageid", row["provenance_id"]),
          page_title: required!(row, "page_title", "provenances.csv"),
          source_category: blank_to_nil(row["source_category"]),
          source_title: blank_to_nil(row["source_title"]),
          url: blank_to_nil(row["url"]),
          created_at: now,
          updated_at: now
        }
      end
    end

    def insert_form_relations!(family_ids, form_ids)
      insert_csv("form_relations.csv", ChengyuFormRelation) do |row, now|
        {
          chengyu_id: lookup!(family_ids, row["family_id"], "family", row["relation_id"]),
          source_form_id: lookup!(form_ids, row["source_form_id"], "source form", row["relation_id"]),
          target_form_id: lookup!(form_ids, row["target_form_id"], "target form", row["relation_id"]),
          source_relation_id: required!(row, "relation_id", "form_relations.csv"),
          relation_type: required!(row, "relation_type", "form_relations.csv"),
          site: blank_to_nil(row["site"]),
          pageid: integer_or_nil(row["pageid"]),
          source_template: blank_to_nil(row["source_template"]),
          cause: blank_to_nil(row["cause"]),
          raw_evidence: blank_to_nil(row["raw_evidence"]),
          merge_policy: blank_to_nil(row["merge_policy"]),
          created_at: now,
          updated_at: now
        }
      end
    end

    def insert_semantic_relations!(family_ids, form_ids)
      insert_csv("semantic_relations.csv", ChengyuSemanticRelation) do |row, now|
        {
          source_chengyu_id: lookup!(family_ids, row["source_family_id"], "source family", row["relation_id"]),
          source_form_id: lookup!(form_ids, row["source_form_id"], "source form", row["relation_id"]),
          target_chengyu_id: optional_lookup(family_ids, row["target_family_id"]),
          target_form_id: optional_lookup(form_ids, row["target_form_id"]),
          source_relation_id: required!(row, "relation_id", "semantic_relations.csv"),
          target_text: required!(row, "target_text", "semantic_relations.csv"),
          relation_type: required!(row, "relation_type", "semantic_relations.csv"),
          relation_language: blank_to_nil(row["relation_language"]),
          site: blank_to_nil(row["site"]),
          pageid: integer_or_nil(row["pageid"]),
          page_title: blank_to_nil(row["page_title"]),
          source_template: blank_to_nil(row["source_template"]),
          raw_definition: blank_to_nil(row["raw_definition"]),
          merge_policy: blank_to_nil(row["merge_policy"]),
          created_at: now,
          updated_at: now
        }
      end
    end

    def insert_csv(name, model)
      now = Time.current
      count = 0
      buffer = []
      each_csv(name) do |row|
        buffer << yield(row.to_h, now)
        count += 1
        if buffer.length >= @batch_size
          model.insert_all!(buffer)
          buffer.clear
        end
      end
      model.insert_all!(buffer) if buffer.any?
      count
    end

    def bulk_insert(model, rows)
      rows.each_slice(@batch_size) { |slice| model.insert_all!(slice) }
    end

    def ensure_character_codepoints!(codepoints)
      existing = codepoints.each_slice(500).flat_map do |slice|
        CharacterCodepoint.where(codepoint: slice).pluck(:codepoint)
      end.to_set
      missing = codepoints.reject { |cp| existing.include?(cp) }
      now = Time.current

      payload = missing.map do |cp|
        glyph = [cp].pack("U")
        unless CharacterData::IndexableCharacter.single?(glyph)
          raise ArgumentError, "Normalized Chengyu contains a non-indexable character U+#{cp.to_s(16).upcase}"
        end
        { codepoint: cp, chr: glyph, created_at: now, updated_at: now }
      end
      bulk_insert(CharacterCodepoint, payload)
      payload.length
    end

    def character_id_map(codepoints)
      codepoints.each_slice(500).each_with_object({}) do |slice, output|
        CharacterCodepoint.where(codepoint: slice).pluck(:codepoint, :id).each do |codepoint, id|
          output[codepoint] = id
        end
      end
    end

    def han_codepoints(form_rows)
      form_rows.flat_map { |row| han_chars(row["form_text"]).map(&:ord) }.uniq.sort
    end

    def han_chars(text)
      text.to_s.each_char.select { |char| han_char?(char) }
    end

    def han_char?(char)
      char.match?(/\A\p{Han}\z/u)
    end

    def split_pipe(value)
      value.to_s.split(/\s*\|\|\s*/).map(&:strip).reject(&:empty?).uniq
    end

    def truthy?(value)
      %w[1 true yes y].include?(value.to_s.strip.downcase)
    end

    def blank_to_nil(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end

    def integer_or_nil(value)
      text = value.to_s.strip
      text.empty? ? nil : Integer(text)
    end

    def integer!(value, field, context)
      Integer(value)
    rescue ArgumentError, TypeError
      raise ArgumentError, "Invalid #{field}=#{value.inspect} in #{context}"
    end

    def time_or_nil(value)
      text = value.to_s.strip
      text.empty? ? nil : Time.iso8601(text)
    rescue ArgumentError
      nil
    end

    def required!(row, key, file)
      value = row[key].to_s.strip
      raise ArgumentError, "Missing #{key} in #{file}" if value.empty?
      value
    end

    def lookup!(mapping, key, kind, context)
      value = mapping[key]
      raise ArgumentError, "Unknown #{kind} #{key.inspect} while importing #{context}" if value.nil?
      value
    end

    def optional_lookup(mapping, key)
      text = key.to_s.strip
      return nil if text.empty?
      mapping[text]
    end
  end
end
