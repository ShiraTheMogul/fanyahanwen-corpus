# frozen_string_literal: true

require "digest"
require "json"
require "pathname"

module DictionaryImport
  # Reads the two reconstructed 切韻 texts already installed in the corpus.
  #
  # This class is deliberately independent of Active Record. It turns the
  # corpus text and metadata into a predictable set of sections and entries;
  # the importer service decides whether those rows are written to the DB.
  class QieyunReconstructionDataset
    class DatasetError < StandardError; end

    DEFAULT_RELATIVE_PATH = "中國漢文/clean/隋朝/切韻"
    TONES = %w[平聲 上聲 去聲 入聲].freeze
    PARSER_NAME = "qieyun_reconstruction_text"
    PARSER_VERSION = "3"

    attr_reader :corpus_root, :relative_path, :metadata, :work_id, :title,
                :source_revision, :editions, :sections, :entries, :input_sha256,
                :path_mismatches

    def initialize(corpus_root:, relative_path: DEFAULT_RELATIVE_PATH)
      @corpus_root = Pathname(corpus_root).expand_path
      @relative_path = relative_path.to_s.tr("\\", "/").sub(%r{\A/+}, "").sub(%r{/+\z}, "")
      @editions = []
      @sections = []
      @entries = []
      @path_mismatches = []
      @global_section_sequence = 0
      @global_entry_sequence = 0
    end

    def load!
      work_root = corpus_root.join(relative_path)
      @work_root = work_root
      metadata_path = work_root.join("metadata.json")
      raise DatasetError, "Missing 切韻 metadata: #{metadata_path}" unless metadata_path.file?

      @metadata = parse_json(metadata_path)
      @work_id = integer!(metadata.fetch("work_id"), "work_id")
      @title = metadata.fetch("title").to_s
      raise DatasetError, "Expected title 切韻, got #{title.inspect}" unless title == "切韻"

      @source_revision = Array(metadata["sources"]).filter_map do |source|
        value = source["revision"].to_s.strip
        value.empty? ? nil : value
      end.first
      edition_rows = Array(metadata["editions"])
      raise DatasetError, "切韻 metadata has no editions" if edition_rows.empty?

      digest = Digest::SHA256.new
      digest << metadata_path.binread

      edition_rows.each_with_index do |edition_metadata, edition_index|
        parse_edition!(edition_metadata, edition_index + 1, digest)
      end

      @input_sha256 = digest.hexdigest
      validate_global_counts!
      self
    end

    def summary
      ensure_loaded!
      {
        "title" => title,
        "corpus_work_id" => work_id,
        "source_revision" => source_revision,
        "edition_count" => editions.length,
        "section_count" => sections.length,
        "entry_count" => entries.length,
        "group_count" => entries.count { |entry| entry.fetch("group_head") },
        "reading_count" => entries.sum { |entry| entry.fetch("fanqie").length },
        "linkable_character_count" => entries.count { |entry| linkable_headword?(entry.fetch("headword")) },
        "unresolved_entry_count" => entries.count { |entry| entry.fetch("contains_unresolved_glyph") },
        "path_mismatch_count" => path_mismatches.length,
        "path_mismatches" => path_mismatches,
        "input_sha256" => input_sha256,
        "editions" => editions
      }
    end

    def linkable_headword?(headword)
      value = headword.to_s
      value.each_char.count == 1 && value.match?(/\p{Han}/) && !value.match?(/[□☒\uFFFD]/)
    end

    private

    def parse_edition!(edition_metadata, edition_sequence, digest)
      edition_id = integer!(edition_metadata.fetch("edition_id"), "edition_id")
      edition_label = edition_metadata.fetch("edition_label").to_s.strip
      raise DatasetError, "Blank edition_label for edition #{edition_id}" if edition_label.empty?

      documents = Array(edition_metadata["documents"])
      raise DatasetError, "Edition #{edition_label} must contain exactly one document" unless documents.length == 1

      document = documents.first
      document_id = integer!(document.fetch("document_id"), "document_id")
      metadata_source_path = document.fetch("path").to_s.tr("\\", "/")
      source_file = document.fetch("file").to_s
      absolute_path, source_path = resolve_document_path!(
        metadata_source_path: metadata_source_path,
        source_file: source_file,
        edition_label: edition_label
      )

      raw = absolute_path.read(encoding: "UTF-8")
      raise DatasetError, "Replacement character found in #{source_path}" if raw.include?("\uFFFD")
      digest << raw.b

      edition_digest = Digest::SHA256.new
      edition_digest << JSON.generate(edition_metadata)
      edition_digest << raw.b

      edition_section_start = sections.length
      edition_entry_start = entries.length
      parse_document!(
        raw: raw,
        edition_id: edition_id,
        edition_label: edition_label,
        edition_sequence: edition_sequence,
        document_id: document_id,
        source_path: source_path,
        source_file: source_file
      )

      edition_sections = sections.length - edition_section_start
      edition_entries = entries.length - edition_entry_start
      edition_groups = entries.drop(edition_entry_start).count { |entry| entry.fetch("group_head") }

      editions << {
        "edition_id" => edition_id,
        "edition_label" => edition_label,
        "edition_sequence" => edition_sequence,
        "document_id" => document_id,
        "source_path" => source_path,
        "metadata_source_path" => metadata_source_path,
        "source_file" => source_file,
        "input_sha256" => edition_digest.hexdigest,
        "section_count" => edition_sections,
        "entry_count" => edition_entries,
        "group_count" => edition_groups,
        "reconstruction" => edition_metadata["reconstruction"] == true,
        "material_type" => edition_metadata["material_type"].to_s,
        "reconstruction_scope" => edition_metadata["reconstruction_scope"].to_s
      }
    end

    def resolve_document_path!(metadata_source_path:, source_file:, edition_label:)
      preferred = corpus_root.join(metadata_source_path)
      return [preferred, metadata_source_path] if preferred.file?

      matches = @work_root.glob("**/#{source_file}").select(&:file?)
      if matches.empty?
        raise DatasetError,
          "Missing edition text: #{preferred} (also searched beneath #{@work_root})"
      end
      if matches.length > 1
        raise DatasetError,
          "Ambiguous edition text for #{edition_label}: #{matches.map(&:to_s).join(', ')}"
      end

      actual = matches.first
      actual_source_path = actual.relative_path_from(corpus_root).to_s.tr("\\", "/")
      path_mismatches << {
        "edition_label" => edition_label,
        "source_file" => source_file,
        "metadata_path" => metadata_source_path,
        "actual_path" => actual_source_path
      }
      [actual, actual_source_path]
    end

    def parse_document!(raw:, edition_id:, edition_label:, edition_sequence:, document_id:, source_path:, source_file:)
      current_tone = nil
      current_section = nil
      edition_section_sequence = 0
      edition_entry_sequence = 0
      group_sequence = 0

      raw.each_line.with_index(1) do |line, line_number|
        text = line.strip
        next if text.empty?

        if TONES.include?(text)
          current_tone = text
          current_section = nil
          next
        end

        if rhyme_heading?(text)
          raise DatasetError, "Rhyme heading before tone at #{source_path}:#{line_number}" unless current_tone

          edition_section_sequence += 1
          @global_section_sequence += 1
          group_sequence = 0
          current_section = {
            "sequence_number" => @global_section_sequence,
            "edition_section_sequence" => edition_section_sequence,
            "edition_id" => edition_id,
            "edition_label" => edition_label,
            "edition_sequence" => edition_sequence,
            "tone_section" => current_tone,
            "rhyme_heading" => text,
            "rhyme_label" => text.sub(/韻\z/, ""),
            "tone" => current_tone,
            "label" => text,
            "document_id" => document_id,
            "source_path" => source_path,
            "source_file" => source_file,
            "metadata" => {
              "edition_id" => edition_id,
              "edition_label" => edition_label,
              "edition_sequence" => edition_sequence,
              "edition_section_sequence" => edition_section_sequence,
              "tone_section" => current_tone,
              "rhyme_heading" => text,
              "reconstruction" => true
            }
          }
          sections << current_section
          next
        end

        raise DatasetError, "Entry before rhyme heading at #{source_path}:#{line_number}: #{text}" unless current_section

        group_head = text.start_with?("○")
        body = group_head ? text.delete_prefix("○") : text
        headword, payload = split_entry!(body, source_path, line_number)

        if group_head
          group_sequence += 1
        elsif group_sequence.zero?
          raise DatasetError, "Non-head entry before first group at #{source_path}:#{line_number}"
        end

        edition_entry_sequence += 1
        @global_entry_sequence += 1
        fanqie = payload.to_s.scan(/(\p{Han}{2})反/).flatten.uniq
        unresolved = headword.match?(/[□☒\uFFFD]/) || text.match?(/[□☒\uFFFD]/)

        entries << {
          "sequence_number" => @global_entry_sequence,
          "edition_entry_sequence" => edition_entry_sequence,
          "section_sequence" => current_section.fetch("sequence_number"),
          "edition_id" => edition_id,
          "edition_label" => edition_label,
          "edition_sequence" => edition_sequence,
          "document_id" => document_id,
          "source_path" => source_path,
          "source_file" => source_file,
          "source_line_start" => line_number,
          "source_line_end" => line_number,
          "tone_section" => current_section.fetch("tone_section"),
          "rhyme_heading" => current_section.fetch("rhyme_heading"),
          "group_sequence" => group_sequence,
          "group_head" => group_head,
          "headword" => headword,
          "definition" => payload.to_s.empty? ? nil : payload,
          "raw_payload" => text,
          "fanqie" => fanqie,
          "contains_unresolved_glyph" => unresolved,
          "metadata" => {
            "edition_id" => edition_id,
            "edition_label" => edition_label,
            "edition_sequence" => edition_sequence,
            "edition_entry_sequence" => edition_entry_sequence,
            "tone_section" => current_section.fetch("tone_section"),
            "rhyme_heading" => current_section.fetch("rhyme_heading"),
            "reconstruction" => true,
            "fanqie" => fanqie
          }
        }
      end
    end

    def split_entry!(body, source_path, line_number)
      chars = body.each_char.to_a
      headword = chars.shift.to_s
      raise DatasetError, "Missing headword at #{source_path}:#{line_number}" if headword.empty?

      remainder = chars.join
      return [headword, nil] if remainder.empty?

      unless remainder.start_with?("〈") && remainder.end_with?("〉")
        raise DatasetError, "Unexpected entry shape at #{source_path}:#{line_number}: #{body}"
      end

      payload_chars = remainder.each_char.to_a
      payload_chars.shift
      payload_chars.pop
      [headword, payload_chars.join]
    end

    def rhyme_heading?(text)
      text.end_with?("韻") && !text.include?("〈") && !text.start_with?("○")
    end

    def parse_json(path)
      JSON.parse(path.read(encoding: "UTF-8"))
    rescue JSON::ParserError => error
      raise DatasetError, "Invalid JSON in #{path}: #{error.message}"
    end

    def integer!(value, label)
      Integer(value)
    rescue ArgumentError, TypeError
      raise DatasetError, "Invalid #{label}: #{value.inspect}"
    end

    def validate_global_counts!
      raise DatasetError, "No 切韻 sections parsed" if sections.empty?
      raise DatasetError, "No 切韻 entries parsed" if entries.empty?
      raise DatasetError, "No reconstructed edition parsed" if editions.empty?
    end

    def ensure_loaded!
      raise DatasetError, "Dataset has not been loaded" unless input_sha256
    end
  end
end
