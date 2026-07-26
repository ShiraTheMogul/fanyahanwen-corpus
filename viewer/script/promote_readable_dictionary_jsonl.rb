#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "time"
require "yaml"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

module DictionaryPublication
  class Error < StandardError; end

  class Promoter
    DEFAULT_CONFIG = Pathname("config/dictionary_import/publication_policy.yml").freeze
    READY_STATUS = "ready_for_import_review"

    attr_reader :cycle_root, :title, :output_root, :config_path

    def initialize(cycle_root:, title:, output_root: nil, config_path: DEFAULT_CONFIG)
      @cycle_root = Pathname(cycle_root).expand_path
      @title = title.to_s.dup.force_encoding(Encoding::UTF_8)
      @output_root = Pathname(output_root || @cycle_root.join("publication", portable_component(@title))).expand_path
      @config_path = Pathname(config_path).expand_path
    end

    def run
      policy = load_policy
      mode = policy.fetch("mode")
      if mode == "review"
        raise Error,
          "#{title} remains review-only by policy. Review its group and section reports before promoting it."
      end
      raise Error, "Unsupported publication mode #{mode.inspect} for #{title}" unless mode == "publish"

      profile = policy.fetch("profile")
      import_plan = cycle_root.join(profile, "import_plan")
      raise Error, "Import-plan directory not found: #{import_plan}" unless import_plan.directory?

      source_paths = Array(policy.fetch("source_files")).map { |name| import_plan.join(name) }
      missing_paths = source_paths.reject(&:file?)
      raise Error, "Missing input JSONL: #{missing_paths.join(', ')}" if missing_paths.any?

      rows = source_paths.flat_map { |path| read_jsonl(path) }
      validate_source_rows!(rows, policy)

      sorted = rows.sort_by do |row|
        [integer_or_large(row["sequence_number"]), integer_or_large(row["document_id"]), integer_or_large(row["source_line_start"])]
      end

      promoted = sorted.each_with_index.map do |row, index|
        promote_row(row, index + 1, policy)
      end

      validate_promoted_rows!(promoted)
      write_outputs(promoted, policy, source_paths)
    end

    private

    def load_policy
      raise Error, "Publication policy not found: #{config_path}" unless config_path.file?

      raw = YAML.safe_load(config_path.read(encoding: "UTF-8"), permitted_classes: [], aliases: false)
      raise Error, "Publication policy root must be a mapping" unless raw.is_a?(Hash)
      raise Error, "Unsupported publication policy version" unless raw["version"].to_i == 1

      works = raw.fetch("works")
      policy = works[title]
      raise Error, "No publication policy configured for #{title}" unless policy.is_a?(Hash)

      policy
    rescue Psych::SyntaxError => error
      raise Error, "Invalid publication policy YAML: #{error.message}"
    end

    def read_jsonl(path)
      rows = []
      File.foreach(path, encoding: "UTF-8").with_index(1) do |line, line_number|
        next if line.strip.empty?

        begin
          value = JSON.parse(line)
        rescue JSON::ParserError => error
          raise Error, "#{path}:#{line_number}: invalid JSON: #{error.message}"
        end
        raise Error, "#{path}:#{line_number}: row is not an object" unless value.is_a?(Hash)

        value["_publication_source_file"] = path.basename.to_s
        rows << value
      end
      rows
    end

    def validate_source_rows!(rows, policy)
      raise Error, "No entries found for #{title}" if rows.empty?

      titles = rows.map { |row| row["dictionary_title"].to_s }.uniq
      raise Error, "Input contains unexpected dictionary titles: #{titles.inspect}" unless titles == [title]

      minimum = Integer(policy.fetch("minimum_entries"))
      maximum = Integer(policy.fetch("maximum_entries"))
      unless rows.length.between?(minimum, maximum)
        raise Error, "#{title} entry count #{rows.length} is outside reviewed range #{minimum}..#{maximum}"
      end

      duplicate_sequences = rows.group_by { |row| row["sequence_number"].to_s }
        .select { |sequence, grouped| !sequence.empty? && grouped.length > 1 }
      if duplicate_sequences.any?
        sample = duplicate_sequences.keys.first(10).join(", ")
        raise Error, "Duplicate source sequence numbers: #{sample}"
      end

      rows.each_with_index do |row, index|
        row_number = index + 1
        %w[dictionary_work_id document_id source_file source_path section_sequence source_line_start source_line_end payload_raw parser parser_version].each do |key|
          value = row[key]
          raise Error, "row #{row_number}: missing #{key}" if value.nil? || value.to_s.empty?
        end
      end
    end

    def promote_row(source_row, new_sequence, policy)
      row = deep_copy(source_row)
      publication_notes = []
      source_structure_notes = Array(row["source_structure_notes"]).map(&:to_s)
      validation_notes = Array(row["validation_notes"]).map(&:to_s)

      original_status = row["dry_run_status"].to_s
      original_review = truthy?(row["parser_review_required"])
      original_gap = truthy?(row["contains_source_gap"])
      original_reasons = Array(row["parser_review_reasons"]).map(&:to_s).reject(&:empty?)
      original_headword = row["headword"].to_s
      original_headwords = Array(row["headwords"]).map(&:to_s)

      marker_raw = row["pronunciation_marker_raw"].to_s.strip
      if Array(policy["non_fanqie_markers"]).map(&:to_s).include?(marker_raw)
        publication_notes << "pronunciation_marker_reclassified=source_note_no_fanqie"
        row["fanqie"] = nil
        row["pronunciation_marker_type"] = "source_note_no_fanqie"
      end

      publication_notes << "publication_policy=readability_first_v1"
      publication_notes << "publication_scope=#{policy.fetch('publication_scope')}"
      publication_notes << "original_dry_run_status=#{original_status}" unless original_status.empty?
      publication_notes << "original_parser_review_required=true" if original_review
      publication_notes << "original_contains_source_gap=true" if original_gap
      publication_notes << "original_parser_review_reasons=#{original_reasons.join('|')}" if original_reasons.any?

      # The normalized database links entry characters one Unicode character at
      # a time. Keep every one-character form exactly as transmitted. Complex or
      # unidentified forms remain visible in payload_raw and are recorded below;
      # they are not normalised, modernised, or replaced with an assumed form.
      linkable_headwords = original_headwords.select { |glyph| glyph.each_char.count == 1 }.uniq
      unlinked_forms = original_headwords.reject { |glyph| glyph.each_char.count == 1 }
      publication_notes << "unlinked_headword_forms=#{JSON.generate(unlinked_forms)}" if unlinked_forms.any?

      primary = if original_headword.each_char.count == 1
                  original_headword
                elsif linkable_headwords.any?
                  publication_notes << "original_primary_headword=#{JSON.generate(original_headword)}" unless original_headword.empty?
                  linkable_headwords.first
                else
                  placeholder = policy.fetch("missing_headword_placeholder").to_s
                  raise Error, "Configured missing-headword placeholder must be one character" unless placeholder.each_char.count == 1

                  publication_notes << "display_headword_placeholder=#{placeholder}"
                  publication_notes << "source_omits_or_does_not_encode_headword=true"
                  placeholder
                end

      linkable_headwords.unshift(primary) unless linkable_headwords.include?(primary)

      if row["sequence_number"].to_i != new_sequence
        publication_notes << "original_sequence_number=#{row['sequence_number']}"
      end

      row.delete("_publication_source_file")
      row["sequence_number"] = new_sequence
      row["headword"] = primary
      row["headwords"] = linkable_headwords
      row["dry_run_status"] = READY_STATUS
      row["parser_review_required"] = false
      row["contains_source_gap"] = false
      row["parser_review_reasons"] = []
      row["source_structure_notes"] = (source_structure_notes + publication_notes).uniq
      row["validation_notes"] = (validation_notes + publication_notes).uniq
      row
    end

    def validate_promoted_rows!(rows)
      expected = (1..rows.length).to_a
      actual = rows.map { |row| Integer(row.fetch("sequence_number")) }
      raise Error, "Promoted sequence numbers are not contiguous" unless actual == expected

      rows.each_with_index do |row, index|
        row_number = index + 1
        raise Error, "row #{row_number}: not marked ready" unless row["dry_run_status"] == READY_STATUS
        raise Error, "row #{row_number}: parser review flag survived" if truthy?(row["parser_review_required"])
        raise Error, "row #{row_number}: source-gap flag survived" if truthy?(row["contains_source_gap"])

        headword = row["headword"].to_s
        headwords = Array(row["headwords"]).map(&:to_s)
        raise Error, "row #{row_number}: primary headword is not one character: #{headword.inspect}" unless headword.each_char.count == 1
        raise Error, "row #{row_number}: primary headword is absent from headwords" unless headwords.include?(headword)
        if headwords.any? { |glyph| glyph.each_char.count != 1 }
          raise Error, "row #{row_number}: non-linkable form survived in headwords: #{headwords.inspect}"
        end
      end
    end

    def write_outputs(rows, policy, source_paths)
      FileUtils.rm_rf(output_root)
      FileUtils.mkdir_p(output_root)

      entries_path = output_root.join("entries.ready_for_import_review.jsonl")
      File.open(entries_path, "w:UTF-8") do |io|
        rows.each { |row| io.puts(JSON.generate(row)) }
      end

      summary = {
        "schema_version" => 1,
        "created_at" => Time.now.utc.iso8601,
        "dictionary_title" => title,
        "profile" => policy.fetch("profile"),
        "publication_scope" => policy.fetch("publication_scope"),
        "entries" => rows.length,
        "sections" => rows.map { |row| row["section_sequence"].to_i }.uniq.length,
        "documents" => rows.map { |row| row["document_id"].to_s }.uniq.length,
        "entries_with_unresolved_glyph" => rows.count { |row| truthy?(row["contains_unresolved_glyph"]) },
        "display_placeholder_entries" => rows.count { |row| Array(row["source_structure_notes"]).any? { |note| note.start_with?("display_headword_placeholder=") } },
        "source_jsonl" => source_paths.map(&:to_s),
        "output_jsonl" => entries_path.to_s,
        "corpus_writes" => 0,
        "database_writes" => 0
      }

      output_root.join("summary.json").write(JSON.pretty_generate(summary) + "\n", encoding: "UTF-8")
      output_root.join("summary.txt").write(summary_text(summary), encoding: "UTF-8")
      write_review_markers(rows)

      puts summary_text(summary)
      summary
    end

    def write_review_markers(rows)
      headers = %w[sequence_number document_id source_path source_line_start source_line_end headword marker notes]
      marked = rows.filter_map do |row|
        notes = Array(row["source_structure_notes"]).grep(/\A(?:display_headword_placeholder|source_omits_or_does_not_encode_headword|original_parser_review_required|original_contains_source_gap|unlinked_headword_forms)=/)
        next if notes.empty?

        {
          "sequence_number" => row["sequence_number"],
          "document_id" => row["document_id"],
          "source_path" => row["source_path"],
          "source_line_start" => row["source_line_start"],
          "source_line_end" => row["source_line_end"],
          "headword" => row["headword"],
          "marker" => "published_with_source_note",
          "notes" => notes.join(" | ")
        }
      end

      CSV.open(output_root.join("publication_markers.csv"), "w", write_headers: true, headers: headers, encoding: "UTF-8") do |csv|
        marked.each { |row| csv << headers.map { |header| row[header] } }
      end
    end

    def summary_text(summary)
      <<~TEXT
        READABILITY-FIRST DICTIONARY PUBLICATION
        ========================================
        Dictionary:                    #{summary['dictionary_title']}
        Publication scope:             #{summary['publication_scope']}
        Entries:                       #{summary['entries']}
        Sections:                      #{summary['sections']}
        Corpus documents represented:  #{summary['documents']}
        Entries with unresolved glyph: #{summary['entries_with_unresolved_glyph']}
        Display-placeholder entries:    #{summary['display_placeholder_entries']}
        Corpus writes:                  0
        Database writes:                0
        Ready JSONL:                    #{summary['output_jsonl']}
      TEXT
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end

    def truthy?(value)
      value == true || value.to_s == "true" || value.to_s == "1"
    end

    def integer_or_large(value)
      Integer(value)
    rescue ArgumentError, TypeError
      9_999_999_999
    end

    def portable_component(value)
      value.to_s.each_char.map do |char|
        if char.match?(/[A-Za-z0-9._-]/)
          char
        else
          format("U+%04X", char.ord)
        end
      end.join("_")
    end
  end

  module CLI
    module_function

    def run(argv)
      options = {}
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: ruby script/promote_readable_dictionary_jsonl.rb --cycle-root DIR --title TITLE [options]"
        opts.on("--cycle-root DIR", "One next_cycle_* directory") { |value| options[:cycle_root] = value }
        opts.on("--title TITLE", "Configured dictionary title, e.g. 集韻 or 玉篇") { |value| options[:title] = value }
        opts.on("--output DIR", "Output directory; defaults below CYCLE_ROOT/publication") { |value| options[:output_root] = value }
        opts.on("--config FILE", "Publication policy YAML") { |value| options[:config_path] = value }
      end
      parser.parse!(argv)

      raise Error, "--cycle-root is required" if options[:cycle_root].to_s.empty?
      raise Error, "--title is required" if options[:title].to_s.empty?
      raise Error, "Unexpected arguments: #{argv.join(' ')}" unless argv.empty?

      Promoter.new(**options).run
      0
    rescue OptionParser::ParseError, Error => error
      warn "dictionary publication failed: #{error.message}"
      warn parser
      2
    end
  end
end

exit DictionaryPublication::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
