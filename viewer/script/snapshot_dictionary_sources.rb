#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "dictionary_import_support"

module SnapshotDictionarySources
  module_function

  Options = Struct.new(:corpus_root, :output, :config, :profile, :strict, keyword_init: true)

  def run(argv)
    options = parse_options(argv)
    corpus_root = Pathname(options.corpus_root).expand_path
    output = Pathname(options.output || "tmp/dictionary_import/source_snapshot_#{DictionaryImportSupport.timestamp}").expand_path
    config_path = Pathname(options.config || DictionaryImportSupport::DEFAULT_CONFIG).expand_path

    abort "Corpus root not found: #{corpus_root}" unless corpus_root.directory?
    config = DictionaryImportSupport.load_config(config_path)
    works = DictionaryImportSupport.configured_works(config, profile: options.profile)

    FileUtils.mkdir_p(output)
    copied_root = output.join("corpus")
    started = Time.now
    work_rows = []
    document_rows = []
    problem_rows = []

    puts "=" * 76
    puts "DICTIONARY SOURCE SNAPSHOT"
    puts "=" * 76
    puts "Corpus root: #{corpus_root}"
    puts "Profile:     #{options.profile}"
    puts "Works:       #{works.length}"
    puts "Output:      #{output}"
    puts

    works.each_with_index do |work, index|
      title = work.fetch("title")
      category = work.fetch("category")
      print format("[%3d/%3d] %-24s ", index + 1, works.length, title)
      matches = DictionaryImportSupport.find_work_directories(
        corpus_root: corpus_root,
        category: category,
        aliases: work.fetch("aliases")
      )

      if matches.empty?
        puts "MISSING"
        problem_rows << problem("missing_work", title, category, "No matching work directory")
        next
      end
      if matches.length > 1
        puts "AMBIGUOUS"
        problem_rows << problem("ambiguous_work", title, category, matches.join(" | "))
        next
      end

      source_dir = matches.first
      metadata_path = source_dir.join("metadata.json")
      unless metadata_path.file?
        puts "NO METADATA"
        problem_rows << problem("missing_metadata", title, category, source_dir.to_s)
        next
      end

      begin
        metadata = DictionaryImportSupport.read_json(metadata_path)
      rescue StandardError => error
        puts "BAD METADATA"
        problem_rows << problem("invalid_metadata", title, category, "#{error.class}: #{error.message}")
        next
      end

      relative_work_dir = DictionaryImportSupport.relative(source_dir, corpus_root)
      target_dir = copied_root.join(relative_work_dir)
      FileUtils.mkdir_p(target_dir.dirname)
      DictionaryImportSupport.retry_fs("copy #{source_dir}") do
        FileUtils.rm_rf(target_dir)
        FileUtils.cp_r(source_dir, target_dir, preserve: true)
      end

      docs = DictionaryImportSupport.metadata_documents(metadata)
      missing_docs = 0
      docs.each_with_index do |document, doc_index|
        source_path = DictionaryImportSupport.resolve_document_path(
          corpus_root: corpus_root,
          work_dir: source_dir,
          document: document
        )
        unless source_path
          missing_docs += 1
          problem_rows << problem(
            "missing_document",
            title,
            category,
            "#{document['file']} | #{document['path']}"
          )
          next
        end

        relative_source = DictionaryImportSupport.relative(source_path, corpus_root)
        copied_path = copied_root.join(relative_source)
        unless copied_path.file?
          FileUtils.mkdir_p(copied_path.dirname)
          DictionaryImportSupport.retry_fs("copy #{source_path}") do
            FileUtils.cp(source_path, copied_path, preserve: true)
          end
        end

        document_rows << {
          "canonical_title" => title,
          "metadata_title" => metadata["title"],
          "category" => category,
          "work_id" => metadata["work_id"],
          "document_sequence" => doc_index + 1,
          "document_id" => document["document_id"],
          "file" => document["file"],
          "source_relative_path" => relative_source,
          "snapshot_relative_path" => DictionaryImportSupport.relative(copied_path, output),
          "bytes" => copied_path.size,
          "sha256" => DictionaryImportSupport.sha256(copied_path),
          "page_title" => document["page_title"],
          "display_title" => document["display_title"],
          "body_start_line" => document["body_start_line"]
        }
      end

      settings = DictionaryImportSupport.work_settings(config, title)
      work_rows << {
        "canonical_title" => title,
        "metadata_title" => metadata["title"],
        "category" => category,
        "work_id" => metadata["work_id"],
        "edition_ids" => Array(metadata["editions"]).map { |row| row["edition_id"] }.compact.join(";"),
        "source_relative_path" => relative_work_dir,
        "snapshot_relative_path" => DictionaryImportSupport.relative(target_dir, output),
        "document_count" => docs.length,
        "missing_document_count" => missing_docs,
        "parser" => settings["parser"],
        "status" => settings["status"]
      }
      puts "COPIED docs=#{docs.length}#{missing_docs.zero? ? '' : " missing=#{missing_docs}"}"
    end

    headers_work = %w[canonical_title metadata_title category work_id edition_ids source_relative_path snapshot_relative_path document_count missing_document_count parser status]
    headers_doc = %w[canonical_title metadata_title category work_id document_sequence document_id file source_relative_path snapshot_relative_path bytes sha256 page_title display_title body_start_line]
    headers_problem = %w[kind canonical_title category detail]
    DictionaryImportSupport.write_csv(output.join("works.csv"), headers_work, work_rows)
    DictionaryImportSupport.write_csv(output.join("documents.csv"), headers_doc, document_rows)
    DictionaryImportSupport.write_csv(output.join("problems.csv"), headers_problem, problem_rows)

    summary = {
      "version" => 1,
      "created_at" => Time.now.utc.iso8601,
      "elapsed_seconds" => (Time.now - started).round(3),
      "corpus_root" => corpus_root.to_s,
      "profile" => options.profile,
      "configured_works" => works.length,
      "copied_works" => work_rows.length,
      "copied_documents" => document_rows.length,
      "problems" => problem_rows.length,
      "output" => output.to_s
    }
    DictionaryImportSupport.write_json(output.join("summary.json"), summary)
    DictionaryImportSupport.atomic_write(output.join("README.txt"), readme(summary))

    puts
    puts "Snapshot complete: #{output}"
    puts "Copied works:      #{work_rows.length}/#{works.length}"
    puts "Copied documents:  #{document_rows.length}"
    puts "Problems:          #{problem_rows.length}"
    puts "Elapsed:           #{format('%.1f', summary['elapsed_seconds'])}s"

    return 2 if options.strict && problem_rows.any?
    0
  end

  def problem(kind, title, category, detail)
    { "kind" => kind, "canonical_title" => title, "category" => category, "detail" => detail }
  end

  def readme(summary)
    <<~TEXT
      Dictionary source snapshot
      ==========================
      Created: #{summary['created_at']}
      Profile: #{summary['profile']}
      Copied works: #{summary['copied_works']}/#{summary['configured_works']}
      Copied documents: #{summary['copied_documents']}
      Problems: #{summary['problems']}

      This directory is an immutable working copy. The scripts in this patch do
      not modify the corpus or the Rails database.

      Run the two dry runs in parallel from the viewer root:

        bash script/run_dictionary_dry_runs.sh "#{summary['output']}"
    TEXT
  end

  def parse_options(argv)
    options = Options.new(profile: "all", strict: false)
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby script/snapshot_dictionary_sources.rb --corpus-root PATH [options]"
      opts.on("--corpus-root PATH", "Corpus root; normally ../corpus") { |value| options.corpus_root = value }
      opts.on("--output PATH", "Snapshot output directory") { |value| options.output = value }
      opts.on("--config PATH", "Source catalogue YAML") { |value| options.config = value }
      opts.on("--profile NAME", "all (default) or starter") { |value| options.profile = value }
      opts.on("--strict", "Exit non-zero when any configured work/document is missing") { options.strict = true }
      opts.on("-h", "--help", "Show help") { puts opts; exit 0 }
    end
    parser.parse!(argv)
    abort parser.to_s unless options.corpus_root
    abort "Unexpected arguments: #{argv.join(' ')}" unless argv.empty?
    options
  end
end

exit SnapshotDictionarySources.run(ARGV)
