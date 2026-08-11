# frozen_string_literal: true

require "set"
require "pathname"

module ChengyuData
  # Builds per-character display marks for the corpus reader.
  #
  # confirmed: a structured Chengyu provenance has been resolved to this corpus
  #            document/work and the form was found at this exact offset.
  # possible:  a known Chengyu form occurs in the visible text. This is a study
  #            aid only and makes no claim about authorial intent or etymology.
  class TextHighlights
    def initialize(text:, document_path: nil, document_paths: nil, corpus_root: nil)
      @text = text.to_s
      @document_path = document_path.to_s.presence
      @document_paths = Array(document_paths).map(&:to_s).reject(&:blank?)
      @corpus_root = corpus_root.to_s.presence
    end

    def marks
      output = Hash.new { |hash, key| hash[key] = { possible: Set.new, confirmed: [], anchor_id: nil } }
      add_possible_marks(output)
      add_confirmed_marks(output)
      output
    rescue ActiveRecord::StatementInvalid, NameError
      {}
    end

    private

    def add_possible_marks(output)
      TextMatcher.current.matches(@text).each do |match|
        (match.start_offset...match.end_offset).each do |index|
          output[index][:possible] << match.display_form
        end
      end
    end

    def add_confirmed_marks(output)
      return unless ChengyuCorpusOccurrence.table_exists?

      if @document_path.present?
        add_document_occurrences(output, @document_path, base_offset: 0)
      elsif @document_paths.any? && @corpus_root.present?
        add_work_occurrences(output)
      end
    end

    def add_work_occurrences(output)
      offset = 0
      first_body = true

      @document_paths.each do |path|
        body = corpus_body(path)
        next if body.blank?

        offset += 2 unless first_body # CorpusViewerController joins work bodies with "\n\n".
        add_document_occurrences(output, path, base_offset: offset)
        offset += body.each_char.count
        first_body = false
      end
    end

    def add_document_occurrences(output, path, base_offset:)
      ChengyuCorpusOccurrence
        .for_document(path)
        .includes(:chengyu)
        .order(:start_offset, :end_offset, :id)
        .each do |occurrence|
          start_index = base_offset + occurrence.start_offset
          end_index = base_offset + occurrence.end_offset
          (start_index...end_index).each do |index|
            output[index][:confirmed] << occurrence.chengyu.display_form
          end
          output[start_index][:anchor_id] ||= occurrence.anchor_id
        end
    end

    def corpus_body(relative_path)
      root = Pathname(File.realpath(@corpus_root))
      absolute = root.join(relative_path)
      raw = absolute.read(encoding: "UTF-8")
      CorpusSearch::DocumentReader.parse(raw).body.to_s
    rescue Errno::ENOENT, Errno::EACCES, SecurityError
      ""
    end
  end
end
