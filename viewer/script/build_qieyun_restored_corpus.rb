#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"
require "time"

module QieyunRestoredCorpus
  class BuildError < StandardError; end

  EDITIONS = [
    {
      key: "fujita",
      csv_name: "切韻 藤田拓海復元.csv",
      directory_name: "藤田拓海",
      edition_label: "藤田拓海復元本",
      reconstructor: "藤田拓海",
      citation: "藤田拓海. 2017. 陸法言『切韻』研究. 二松学舎大学博士学位論文."
    },
    {
      key: "li",
      csv_name: "切韻 李永富復元.csv",
      directory_name: "李永富",
      edition_label: "李永富復元本",
      reconstructor: "李永富",
      citation: "李永富復元資料（nk2028/qieyun-restored 所收）."
    }
  ].freeze

  REQUIRED_HEADERS = %w[頁 行 音韻地位描述 聲調 韻目 序数 小韻 音類 字頭 釋義].freeze
  DEFAULT_TARGET = "中國漢文/clean/隋朝/隋/切韻"
  SOURCE_REPOSITORY = "https://github.com/nk2028/qieyun-restored"

  class Builder
    attr_reader :source_dir, :output_dir, :target_relative_path, :ids, :source_revision

    def initialize(source_dir:, output_dir:, target_relative_path: DEFAULT_TARGET, ids: {}, source_revision: nil)
      @source_dir = Pathname(source_dir).expand_path
      @output_dir = Pathname(output_dir).expand_path
      @target_relative_path = normalize_relative_path(target_relative_path)
      @ids = ids.transform_keys(&:to_sym)
      @source_revision = source_revision.to_s.strip
    end

    def build
      validate_inputs!
      @source_revision = detect_source_revision if source_revision.empty?
      FileUtils.rm_rf(output_dir)
      FileUtils.mkdir_p(output_dir)

      overlay_name = apply_ready? ? "corpus_overlay" : "review_only_corpus_overlay"
      overlay_root = output_dir.join(overlay_name)
      work_root = overlay_root.join(target_relative_path)
      report_root = output_dir.join("reports")
      FileUtils.mkdir_p(work_root)
      FileUtils.mkdir_p(report_root)

      edition_results = EDITIONS.map do |edition|
        build_edition(edition, work_root, report_root)
      end

      metadata = build_metadata(edition_results)
      write_json(work_root.join("metadata.json"), metadata)

      missing = missing_ids
      summary = {
        "schema_version" => 1,
        "created_at" => Time.now.utc.iso8601,
        "source_directory" => source_dir.to_s,
        "source_repository" => SOURCE_REPOSITORY,
        "source_revision" => source_revision.empty? ? nil : source_revision,
        "target_relative_path" => target_relative_path,
        "output_overlay" => overlay_root.to_s,
        "apply_ready" => missing.empty?,
        "missing_ids" => missing,
        "editions" => edition_results.map { |result| result.fetch(:summary) },
        "replacement_characters" => edition_results.sum { |result| result.fetch(:summary).fetch("replacement_characters") },
        "unusual_headwords" => edition_results.sum { |result| result.fetch(:summary).fetch("unusual_headwords") }
      }
      write_json(report_root.join("summary.json"), summary)
      write_json(report_root.join("id_requirements.json"), id_requirements)
      output_dir.join("README.txt").write(readme(summary), encoding: "UTF-8")

      summary
    end

    private

    def validate_inputs!
      raise BuildError, "Source directory not found: #{source_dir}" unless source_dir.directory?
      raise BuildError, "Refusing to write to filesystem root" if output_dir == Pathname("/")
      raise BuildError, "Refusing to write into the source directory" if output_dir == source_dir || output_dir.to_s.start_with?(source_dir.to_s + File::SEPARATOR)

      EDITIONS.each do |edition|
        path = source_dir.join(edition.fetch(:csv_name))
        raise BuildError, "Missing source CSV: #{path}" unless path.file?
      end
    end

    def build_edition(edition, work_root, report_root)
      csv_path = source_dir.join(edition.fetch(:csv_name))
      rows = read_rows(csv_path)
      rendered = render_text(edition, rows)

      relative_document_path = Pathname(target_relative_path)
        .join("reconstruction", edition.fetch(:directory_name), "切韻（#{edition.fetch(:edition_label)}）.txt")
        .to_s
      document_path = work_root.join("reconstruction", edition.fetch(:directory_name), "切韻（#{edition.fetch(:edition_label)}）.txt")
      FileUtils.mkdir_p(document_path.dirname)
      document_path.write(rendered.fetch(:text), encoding: "UTF-8")

      map_path = report_root.join("#{edition.fetch(:key)}_line_map.csv")
      CSV.open(map_path, "wb", write_headers: true, headers: line_map_headers, force_quotes: true) do |csv|
        rendered.fetch(:line_map).each do |row|
          csv << line_map_headers.map { |header| row.fetch(header) }
        end
      end

      summary = {
        "key" => edition.fetch(:key),
        "edition_label" => edition.fetch(:edition_label),
        "source_csv" => csv_path.to_s,
        "source_sha256" => Digest::SHA256.file(csv_path).hexdigest,
        "output_path" => relative_document_path,
        "rows" => rows.length,
        "small_rimes" => rows.map { |row| [row.fetch("聲調"), row.fetch("韻目"), row.fetch("小韻")] }.uniq.length,
        "rhyme_sections" => rows.map { |row| [row.fetch("聲調"), row.fetch("韻目")] }.uniq.length,
        "replacement_characters" => rendered.fetch(:text).count("\uFFFD"),
        "unusual_headwords" => rows.count { |row| row.fetch("字頭").each_char.count != 1 },
        "empty_definitions" => rows.count { |row| rendered_definition(row.fetch("釋義")).empty? },
        "source_empty_definitions" => rows.count { |row| row.fetch("釋義").empty? },
        "output_lines" => rendered.fetch(:text).lines.length
      }

      {
        edition: edition,
        relative_document_path: relative_document_path,
        document_file: document_path.basename.to_s,
        summary: summary
      }
    end

    def read_rows(csv_path)
      table = CSV.read(csv_path, headers: true, encoding: "bom|utf-8")
      headers = table.headers.compact.map(&:to_s)
      missing = REQUIRED_HEADERS - headers
      raise BuildError, "#{csv_path.basename}: missing columns #{missing.join(', ')}" if missing.any?

      rows = table.each_with_index.map do |row, index|
        normalized = REQUIRED_HEADERS.to_h { |header| [header, row[header].to_s.strip] }
        normalized["_source_row"] = index + 2
        normalized
      end

      rows.reject! { |row| row.fetch("字頭").empty? }
      raise BuildError, "#{csv_path.basename}: no lexical rows" if rows.empty?

      rows.sort_by do |row|
        sequence = integer_or_nil(row.fetch("序数"))
        [sequence || 9_999_999, row.fetch("_source_row")]
      end
    end

    def render_text(edition, rows)
      # The .txt file contains only the reconstructed Literary Chinese text.
      # Title, edition and responsibility statements belong in metadata.json.
      lines = []
      line_map = []
      previous_tone = nil
      previous_rhyme = nil
      previous_small_rime = nil

      rows.each do |row|
        tone = row.fetch("聲調")
        rhyme = row.fetch("韻目")
        small_rime = row.fetch("小韻")

        if tone != previous_tone
          lines << "" if lines.any? && lines.last != ""
          lines << "#{tone}聲"
          lines << ""
          previous_tone = tone
          previous_rhyme = nil
          previous_small_rime = nil
        end

        if rhyme != previous_rhyme
          lines << "" if lines.any? && lines.last != ""
          lines << "#{rhyme}韻"
          lines << ""
          previous_rhyme = rhyme
          previous_small_rime = nil
        end

        group_head = small_rime != previous_small_rime
        prefix = group_head ? "○" : ""
        source_definition = row.fetch("釋義")
        definition = rendered_definition(source_definition)
        lexical_line = +"#{prefix}#{row.fetch('字頭')}"
        lexical_line << "〈#{definition}〉" unless definition.empty?
        lines << lexical_line
        output_line = lines.length

        line_map << {
          "source_csv" => edition.fetch(:csv_name),
          "source_row" => row.fetch("_source_row"),
          "output_line" => output_line,
          "tone" => tone,
          "rhyme" => rhyme,
          "sequence" => row.fetch("序数"),
          "small_rime" => small_rime,
          "phonological_position" => row.fetch("音韻地位描述"),
          "sound_class" => row.fetch("音類"),
          "headword" => row.fetch("字頭"),
          "definition" => source_definition,
          "rendered_definition" => definition,
          "group_head" => group_head
        }

        previous_small_rime = small_rime
      end

      { text: lines.join("\n") + "\n", line_map: line_map }
    end

    def build_metadata(edition_results)
      {
        "schema_version" => 1,
        "work_id" => integer_or_nil(ids[:work_id]),
        "corpus_root" => "中國漢文",
        "title" => "切韻",
        "is_compilation" => false,
        "authors" => [
          { "name" => "陸法言", "role" => "author" }
        ],
        "date_label" => "隋",
        "macro_region" => "中國",
        "period" => "隋朝",
        "polity" => "隋",
        "categories" => ["韻書"],
        "sources" => [
          {
            "citation" => "nk2028. qieyun-restored: Restored Qieyun and other data from Fujita (2017; 2023).",
            "url" => SOURCE_REPOSITORY,
            "revision" => source_revision.empty? ? nil : source_revision
          }.compact
        ],
        "rights" => {
          "license" => "MIT",
          "source" => SOURCE_REPOSITORY
        },
        "known_commentaries" => [],
        "editions" => edition_results.map { |result| edition_metadata(result) }
      }
    end

    def edition_metadata(result)
      edition = result.fetch(:edition)
      key = edition.fetch(:key)
      edition_id = integer_or_nil(ids["#{key}_edition_id".to_sym])
      document_id = integer_or_nil(ids["#{key}_document_id".to_sym])

      {
        "edition_id" => edition_id,
        "edition_label" => edition.fetch(:edition_label),
        "material_type" => "reconstruction",
        "reconstruction" => true,
        "reconstruction_scope" => "complete restored text",
        "editors" => [
          { "name" => edition.fetch(:reconstructor), "role" => "reconstruction editor" }
        ],
        "contributors" => [
          { "name" => "nk2028", "role" => "digital editor" }
        ],
        "sources" => [
          { "citation" => edition.fetch(:citation) },
          {
            "citation" => "nk2028/qieyun-restored: #{edition.fetch(:csv_name)}",
            "url" => SOURCE_REPOSITORY,
            "revision" => source_revision.empty? ? nil : source_revision
          }.compact
        ],
        "rights" => {
          "license" => "MIT",
          "source" => SOURCE_REPOSITORY
        },
        "documents" => [
          {
            "document_id" => document_id,
            "file" => result.fetch(:document_file),
            "path" => result.fetch(:relative_document_path),
            "title" => "切韻 (#{edition.fetch(:edition_label)})",
            "page_title" => "切韻 (#{edition.fetch(:edition_label)})",
            "display_title" => "切韻",
            "body_start_line" => 1,
            "material_type" => "reconstruction",
            "reconstruction" => true,
            "reconstruction_scope" => "complete restored text",
            "source_csv" => edition.fetch(:csv_name),
            "source_repository" => SOURCE_REPOSITORY,
            "source_revision" => source_revision.empty? ? nil : source_revision
          }.compact
        ]
      }
    end

    def apply_ready?
      missing_ids.empty?
    end

    def missing_ids
      id_requirements.select { |_key, value| value.nil? }.keys
    end

    def id_requirements
      {
        "work_id" => integer_or_nil(ids[:work_id]),
        "fujita_edition_id" => integer_or_nil(ids[:fujita_edition_id]),
        "fujita_document_id" => integer_or_nil(ids[:fujita_document_id]),
        "li_edition_id" => integer_or_nil(ids[:li_edition_id]),
        "li_document_id" => integer_or_nil(ids[:li_document_id])
      }
    end

    def line_map_headers
      %w[source_csv source_row output_line tone rhyme sequence small_rime phonological_position sound_class headword definition rendered_definition group_head]
    end

    def rendered_definition(value)
      text = value.to_s.strip
      return "" if text.match?(/\A[.．。\s]+\z/u)

      text
    end

    def detect_source_revision
      stdout, _stderr, status = Open3.capture3(
        "git",
        "-c",
        "safe.directory=#{source_dir}",
        "-C",
        source_dir.to_s,
        "rev-parse",
        "HEAD"
      )
      status.success? ? stdout.to_s.strip : ""
    rescue Errno::ENOENT
      ""
    end

    def write_json(path, payload)
      FileUtils.mkdir_p(path.dirname)
      path.write(JSON.pretty_generate(payload) + "\n", encoding: "UTF-8")
    end

    def integer_or_nil(value)
      Integer(value) if value.to_s.match?(/\A\d+\z/)
    rescue ArgumentError, TypeError
      nil
    end

    def normalize_relative_path(value)
      path = value.to_s.tr("\\", "/").sub(%r{\A/+}, "").sub(%r{/+\z}, "")
      raise BuildError, "Target path is empty" if path.empty?
      raise BuildError, "Target path may not contain '..'" if path.split("/").include?("..")

      path
    end

    def readme(summary)
      readiness = if summary.fetch("apply_ready")
                    "This package has complete numeric IDs and its corpus_overlay directory is ready for audit."
                  else
                    "This is a review-only package. Do not copy it into the corpus until the IDs listed in reports/id_requirements.json are assigned."
                  end

      <<~TEXT
        QIEYUN RESTORED CORPUS BUILD
        ============================

        #{readiness}

        Source repository:
          #{SOURCE_REPOSITORY}

        Target work:
          #{target_relative_path}

        The two restored texts remain separate editions of the historical work 切韻.
        Each CSV row is rendered as readable Literary Chinese. Titles and editor
        credits remain in metadata.json rather than being inserted into the body.
        A circle marks the first character of each reconstructed small rime. Exact CSV-to-text line
        mappings are retained under reports/ for later dictionary import auditing.

        No existing corpus file is read, modified, or deleted by this script.
      TEXT
    end
  end

  module CLI
    module_function

    def run(argv)
      options = {
        target_relative_path: DEFAULT_TARGET,
        ids: {}
      }

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: ruby script/build_qieyun_restored_corpus.rb --source-dir DIR --output DIR [ID options]"
        opts.on("--source-dir DIR", "Local checkout or extracted directory of nk2028/qieyun-restored") { |value| options[:source_dir] = value }
        opts.on("--output DIR", "Review/build output directory") { |value| options[:output_dir] = value }
        opts.on("--target-relative-path PATH", "Corpus-relative work folder (default: #{DEFAULT_TARGET})") { |value| options[:target_relative_path] = value }
        opts.on("--source-revision SHA", "qieyun-restored commit SHA recorded in metadata") { |value| options[:source_revision] = value }
        opts.on("--work-id ID", Integer) { |value| options[:ids][:work_id] = value }
        opts.on("--fujita-edition-id ID", Integer) { |value| options[:ids][:fujita_edition_id] = value }
        opts.on("--fujita-document-id ID", Integer) { |value| options[:ids][:fujita_document_id] = value }
        opts.on("--li-edition-id ID", Integer) { |value| options[:ids][:li_edition_id] = value }
        opts.on("--li-document-id ID", Integer) { |value| options[:ids][:li_document_id] = value }
      end
      parser.parse!(argv)

      raise BuildError, "--source-dir is required" if options[:source_dir].to_s.empty?
      raise BuildError, "--output is required" if options[:output_dir].to_s.empty?

      summary = Builder.new(**options).build
      puts JSON.pretty_generate(summary)
      0
    rescue OptionParser::ParseError, BuildError => error
      warn "qieyun-restored build failed: #{error.message}"
      warn parser
      2
    end
  end
end

exit QieyunRestoredCorpus::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
