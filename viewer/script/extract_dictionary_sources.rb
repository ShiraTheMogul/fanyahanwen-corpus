#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "dictionary_import/support"

module ExtractDictionarySources
  module_function

  Options = Struct.new(
    :corpus_root, :viewer_root, :output, :config, :profile, :strict,
    keyword_init: true
  )

  Candidate = Struct.new(
    :work_dir, :metadata_path, :metadata, :match_kind, :matched_alias,
    :subset_documents,
    keyword_init: true
  )

  def run(argv)
    options = parse_options(argv)
    corpus_root = Pathname(options.corpus_root).expand_path
    viewer_root = Pathname(options.viewer_root || Dir.pwd).expand_path
    output = Pathname(options.output || "tmp/dictionary_import/source_bundle_#{DictionaryImport::Support.timestamp}").expand_path
    config_path = Pathname(options.config || DictionaryImport::Support::DEFAULT_CONFIG).expand_path

    abort "Corpus root not found: #{corpus_root}" unless corpus_root.directory?
    abort "Configuration not found: #{config_path}" unless config_path.file?

    config = DictionaryImport::Support.load_config(config_path)
    requested = DictionaryImport::Support.configured_works(config, profile: options.profile)
    FileUtils.mkdir_p(output)

    puts "=" * 78
    puts "DICTIONARY SOURCE EXTRACTOR"
    puts "=" * 78
    puts "Corpus:      #{corpus_root}"
    puts "Viewer:      #{viewer_root}"
    puts "Profile:     #{options.profile}"
    puts "Named works: #{requested.length}"
    puts "Output:      #{output}"
    puts

    started = Time.now
    direct, unresolved = direct_candidates(corpus_root, requested)
    full_index = unresolved.empty? ? {} : build_full_index(corpus_root, unresolved)

    selected_rows = []
    problem_rows = []
    copied_work_rows = []
    document_rows = []
    file_rows = []
    copied_by_source = {}

    requested.each_with_index do |request, index|
      title = request.fetch("title")
      print format("[%3d/%3d] %-28s ", index + 1, requested.length, title)
      candidates = Array(direct[title])
      candidates = candidates_from_index(full_index, request) if candidates.empty?

      if candidates.empty?
        puts "MISSING"
        problem_rows << problem("missing_work", request, "No exact directory, metadata-title, or document-subset match")
        next
      end

      distinct = candidates.uniq { |candidate| candidate.work_dir.to_s }
      if distinct.length > 1
        puts "AMBIGUOUS (#{distinct.length})"
        problem_rows << problem(
          "ambiguous_work",
          request,
          distinct.map { |row| "#{row.match_kind}:#{DictionaryImport::Support.relative(row.work_dir, corpus_root)}" }.join(" | ")
        )
        next
      end

      candidate = distinct.first
      source_key = candidate.work_dir.to_s
      snapshot_dir = copied_by_source[source_key]
      unless snapshot_dir
        work_id = candidate.metadata["work_id"]
        snapshot_dir = output.join("sources", DictionaryImport::Support.portable_work_dir(work_id, candidate.metadata["title"] || title))
        copy_complete_work(candidate.work_dir, snapshot_dir)
        copied_by_source[source_key] = snapshot_dir

        copied_work_rows << copied_work_row(candidate, corpus_root, output, snapshot_dir)
        append_file_rows(file_rows, snapshot_dir, output, candidate.work_dir, corpus_root)
      end

      subset_keys = Array(candidate.subset_documents).map { |row| row["document_id"].to_s }.to_set
      docs = DictionaryImport::Support.metadata_documents(candidate.metadata)
      missing = 0
      docs.each_with_index do |(container, parent, document), doc_index|
        source_path = DictionaryImport::Support.resolve_document_path(
          corpus_root: corpus_root,
          work_dir: candidate.work_dir,
          document: document
        )
        if source_path.nil?
          missing += 1
          problem_rows << problem(
            "missing_document",
            request,
            "#{document['document_id']} | #{document['file']} | #{document['path']}"
          )
          next
        end

        snapshot_path = snapshot_dir.join("documents", format("%04d--%s", doc_index + 1, DictionaryImport::Support.portable_component(document["file"])))
        FileUtils.mkdir_p(snapshot_path.dirname)
        unless snapshot_path.file?
          DictionaryImport::Support.retry_fs("copy #{source_path}") do
            FileUtils.cp(source_path, snapshot_path, preserve: true)
          end
        end

        file_rows << {
          "kind" => "declared_document_copy",
          "source_relative_path" => relative_source = DictionaryImport::Support.relative(source_path, corpus_root),
          "snapshot_relative_path" => DictionaryImport::Support.relative(snapshot_path, output),
          "bytes" => snapshot_path.size,
          "sha256" => DictionaryImport::Support.sha256(snapshot_path)
        }

        document_rows << {
          "configured_title" => title,
          "metadata_title" => candidate.metadata["title"],
          "category" => request["category"],
          "match_kind" => candidate.match_kind,
          "matched_alias" => candidate.matched_alias,
          "work_id" => candidate.metadata["work_id"],
          "edition_id" => parent["edition_id"],
          "edition_label" => parent["edition_label"],
          "document_sequence" => doc_index + 1,
          "document_id" => document["document_id"],
          "document_container" => container,
          "file" => document["file"],
          "title" => document["title"],
          "page_title" => document["page_title"],
          "display_title" => document["display_title"],
          "body_start_line" => document["body_start_line"],
          "source_relative_path" => relative_source,
          "snapshot_relative_path" => DictionaryImport::Support.relative(snapshot_path, output),
          "bytes" => snapshot_path.size,
          "sha256" => DictionaryImport::Support.sha256(snapshot_path),
          "selected_subset_document" => subset_keys.empty? ? true : subset_keys.include?(document["document_id"].to_s)
        }
      end

      settings = DictionaryImport::Support.work_settings(config, title)
      selected_rows << {
        "configured_title" => title,
        "category" => request["category"],
        "aliases" => request["aliases"].join(";"),
        "metadata_title" => candidate.metadata["title"],
        "work_id" => candidate.metadata["work_id"],
        "match_kind" => candidate.match_kind,
        "matched_alias" => candidate.matched_alias,
        "source_relative_path" => DictionaryImport::Support.relative(candidate.work_dir, corpus_root),
        "snapshot_relative_path" => DictionaryImport::Support.relative(snapshot_dir, output),
        "document_count" => docs.length,
        "missing_document_count" => missing,
        "subset_document_count" => subset_keys.length,
        "parser" => settings["parser"],
        "configured_status" => settings["status"]
      }
      puts "COPIED work_id=#{candidate.metadata['work_id']} docs=#{docs.length} match=#{candidate.match_kind}"
    rescue StandardError => error
      puts "ERROR #{error.class}"
      problem_rows << problem("extract_error", request, "#{error.class}: #{error.message}")
    end

    copy_viewer_context(viewer_root, output, file_rows)
    extract_manifest_rows(viewer_root, output, document_rows)

    DictionaryImport::Support.write_csv(
      output.join("catalogue.csv"),
      %w[configured_title category aliases metadata_title work_id match_kind matched_alias source_relative_path snapshot_relative_path document_count missing_document_count subset_document_count parser configured_status],
      selected_rows
    )
    DictionaryImport::Support.write_csv(
      output.join("works.csv"),
      %w[work_id metadata_title source_relative_path snapshot_relative_path schema_version corpus_root macro_region period polity is_compilation],
      copied_work_rows
    )
    DictionaryImport::Support.write_csv(
      output.join("documents.csv"),
      %w[configured_title metadata_title category match_kind matched_alias work_id edition_id edition_label document_sequence document_id document_container file title page_title display_title body_start_line source_relative_path snapshot_relative_path bytes sha256 selected_subset_document],
      document_rows
    )
    DictionaryImport::Support.write_csv(
      output.join("files.csv"),
      %w[kind source_relative_path snapshot_relative_path bytes sha256],
      file_rows
    )
    DictionaryImport::Support.write_csv(
      output.join("problems.csv"),
      %w[kind configured_title category detail],
      problem_rows
    )
    selected_by_title = selected_rows.to_h { |row| [row.fetch("configured_title"), row] }
    problems_by_title = problem_rows.group_by { |row| row.fetch("configured_title") }
    request_status_rows = requested.map do |request|
      selected = selected_by_title[request.fetch("title")]
      problems = Array(problems_by_title[request.fetch("title")])
      status = if selected
                 selected["missing_document_count"].to_i.positive? ? "matched_with_missing_documents" : "matched"
               elsif problems.any? { |row| row["kind"] == "ambiguous_work" }
                 "ambiguous"
               elsif problems.any? { |row| row["kind"] == "extract_error" }
                 "extract_error"
               else
                 "missing"
               end
      {
        "configured_title" => request.fetch("title"),
        "category" => request.fetch("category"),
        "aliases" => request.fetch("aliases").join(";"),
        "status" => status,
        "metadata_title" => selected && selected["metadata_title"],
        "work_id" => selected && selected["work_id"],
        "match_kind" => selected && selected["match_kind"],
        "source_relative_path" => selected && selected["source_relative_path"],
        "document_count" => selected && selected["document_count"],
        "missing_document_count" => selected && selected["missing_document_count"],
        "problem_kinds" => problems.map { |row| row["kind"] }.uniq.join(";"),
        "problem_details" => problems.map { |row| row["detail"] }.join(" | ")
      }
    end
    DictionaryImport::Support.write_csv(
      output.join("requested_catalogue.csv"),
      %w[configured_title category aliases status metadata_title work_id match_kind source_relative_path document_count missing_document_count problem_kinds problem_details],
      request_status_rows
    )

    problem_counts = problem_rows.each_with_object(Hash.new(0)) { |row, out| out[row["kind"]] += 1 }
    summary = {
      "version" => 3,
      "created_at" => Time.now.utc.iso8601,
      "elapsed_seconds" => (Time.now - started).round(3),
      "profile" => options.profile,
      "configured_works" => requested.length,
      "matched_catalogue_items" => selected_rows.length,
      "distinct_copied_work_folders" => copied_work_rows.length,
      "copied_documents" => document_rows.length,
      "copied_files" => file_rows.length,
      "problems" => problem_rows.length,
      "problem_counts" => problem_counts,
      "missing_requested_works" => request_status_rows.count { |row| row["status"] == "missing" },
      "ambiguous_requested_works" => request_status_rows.count { |row| row["status"] == "ambiguous" },
      "matched_works_with_missing_documents" => request_status_rows.count { |row| row["status"] == "matched_with_missing_documents" },
      "corpus_root" => corpus_root.to_s,
      "viewer_root" => viewer_root.to_s,
      "output" => output.to_s,
      "corpus_git" => git_context(corpus_root),
      "viewer_git" => git_context(viewer_root)
    }
    DictionaryImport::Support.write_json(output.join("summary.json"), summary)
    DictionaryImport::Support.atomic_write(output.join("README.txt"), readme(summary))

    puts
    puts "Extraction complete"
    puts "  Catalogue matches: #{selected_rows.length}/#{requested.length}"
    puts "  Work folders:      #{copied_work_rows.length}"
    puts "  Documents:         #{document_rows.length}"
    puts "  Problems:          #{problem_rows.length}"
    puts "  Elapsed:           #{format('%.1f', summary['elapsed_seconds'])}s"
    puts "  Output:            #{output}"

    return 2 if options.strict && problem_rows.any?
    0
  end

  def direct_candidates(corpus_root, requests)
    found = {}
    unresolved = []
    category_root = corpus_root.join("四庫全書", "clean", "經部", "小學類")

    requests.each do |request|
      category_dir = category_root.join(request.fetch("category"))
      matches = []
      if category_dir.directory?
        alias_keys = request.fetch("aliases").map { |value| DictionaryImport::Support.title_key(value) }.to_set
        Dir.children(category_dir.to_s, encoding: Encoding::UTF_8).each do |name|
          path = category_dir.join(name)
          next unless path.directory? && path.join("metadata.json").file?
          next unless alias_keys.include?(DictionaryImport::Support.title_key(name))
          metadata = DictionaryImport::Support.read_json(path.join("metadata.json"))
          matches << Candidate.new(
            work_dir: path,
            metadata_path: path.join("metadata.json"),
            metadata: metadata,
            match_kind: "siku_category_directory",
            matched_alias: name,
            subset_documents: []
          )
        end
      end
      if matches.empty?
        unresolved << request
      else
        found[request.fetch("title")] = matches
      end
    end
    [found, unresolved]
  end

  def build_full_index(corpus_root, unresolved)
    wanted = unresolved.flat_map { |row| row.fetch("aliases") }.to_h do |alias_name|
      [DictionaryImport::Support.title_key(alias_name), alias_name]
    end
    index = Hash.new { |hash, key| hash[key] = [] }

    puts
    puts "Building one metadata-aware corpus index for #{wanted.length} unresolved names..."
    metadata_paths = DictionaryImport::Support.clean_metadata_paths(corpus_root)
    metadata_paths.each_with_index do |metadata_path, index_number|
      begin
        metadata = DictionaryImport::Support.read_json(metadata_path)
      rescue StandardError => error
        warn "[metadata] skipped #{metadata_path}: #{error.class}: #{error.message}"
        next
      end
      work_dir = metadata_path.dirname
      title_values = [metadata["title"], work_dir.basename.to_s, *Array(metadata["alternate_titles"]), *Array(metadata["aliases"])]
      title_values.compact.each do |value|
        key = DictionaryImport::Support.title_key(value)
        next unless wanted.key?(key)
        index[key] << Candidate.new(
          work_dir: work_dir,
          metadata_path: metadata_path,
          metadata: metadata,
          match_kind: "corpus_metadata_title",
          matched_alias: wanted[key],
          subset_documents: []
        )
      end

      DictionaryImport::Support.metadata_documents(metadata).each do |_container, _parent, document|
        searchable = [document["file"], document["title"], document["page_title"], document["display_title"]].compact
        searchable.each do |value|
          value_key = DictionaryImport::Support.title_key(value)
          wanted.each do |wanted_key, alias_name|
            next unless value_key == wanted_key || value_key.start_with?(wanted_key + "卷") || value_key.start_with?(wanted_key + "考證") || value_key.start_with?(wanted_key + "音釋")
            candidate = Candidate.new(
              work_dir: work_dir,
              metadata_path: metadata_path,
              metadata: metadata,
              match_kind: "embedded_document_subset",
              matched_alias: alias_name,
              subset_documents: [document]
            )
            index[wanted_key] << candidate
          end
        end
      end
      puts "  parsed metadata #{index_number + 1}/#{metadata_paths.length}; candidate rows=#{index.values.sum(&:length)}" if ((index_number + 1) % 10_000).zero?
    end
    puts "Corpus index complete: metadata=#{metadata_paths.length}, candidate rows=#{index.values.sum(&:length)}"
    index
  end

  def candidates_from_index(index, request)
    request.fetch("aliases").flat_map do |name|
      Array(index[DictionaryImport::Support.title_key(name)])
    end.group_by { |candidate| candidate.work_dir.to_s }.map do |_path, candidates|
      work = candidates.first
      subset = candidates.flat_map { |candidate| Array(candidate.subset_documents) }.uniq { |row| (row["document_id"].to_s.empty? ? row["file"].to_s : row["document_id"].to_s) }
      work.subset_documents = subset
      work
    end
  end

  def copy_complete_work(source_dir, snapshot_dir)
    DictionaryImport::Support.retry_fs("copy work #{source_dir}") do
      FileUtils.rm_rf(snapshot_dir)
      FileUtils.mkdir_p(snapshot_dir)
      FileUtils.cp_r(source_dir, snapshot_dir.join("work_folder"), preserve: true)
      FileUtils.cp(source_dir.join("metadata.json"), snapshot_dir.join("metadata.json"), preserve: true)
      DictionaryImport::Support.atomic_write(snapshot_dir.join("SOURCE_PATH.txt"), source_dir.to_s + "\n")
    end
  end

  def copied_work_row(candidate, corpus_root, output, snapshot_dir)
    metadata = candidate.metadata
    {
      "work_id" => metadata["work_id"],
      "metadata_title" => metadata["title"],
      "source_relative_path" => DictionaryImport::Support.relative(candidate.work_dir, corpus_root),
      "snapshot_relative_path" => DictionaryImport::Support.relative(snapshot_dir, output),
      "schema_version" => metadata["schema_version"],
      "corpus_root" => metadata["corpus_root"],
      "macro_region" => metadata["macro_region"],
      "period" => metadata["period"],
      "polity" => metadata["polity"],
      "is_compilation" => metadata["is_compilation"]
    }
  end

  def append_file_rows(rows, snapshot_dir, output, source_dir, corpus_root)
    Find.find(snapshot_dir.to_s) do |name|
      path = Pathname(name)
      next unless path.file?
      relative_inside = path.relative_path_from(snapshot_dir).to_s
      source_path = if relative_inside.start_with?("work_folder/")
                      source_dir.join(relative_inside.delete_prefix("work_folder/"))
                    elsif relative_inside == "metadata.json"
                      source_dir.join("metadata.json")
                    end
      rows << {
        "kind" => "corpus_source",
        "source_relative_path" => source_path ? DictionaryImport::Support.relative(source_path, corpus_root) : nil,
        "snapshot_relative_path" => DictionaryImport::Support.relative(path, output),
        "bytes" => path.size,
        "sha256" => DictionaryImport::Support.sha256(path)
      }
    end
  end

  def copy_viewer_context(viewer_root, output, file_rows)
    return unless viewer_root.directory?

    patterns = [
      "resources/importers/**/*",
      "app/models/character_property.rb",
      "db/migrate/*character_propert*",
      "lib/tasks/guangyun.rake",
      "app/controllers/guangyun*",
      "app/views/guangyun*/**/*",
      "app/views/characters/show.html.erb",
      "Gemfile",
      "Gemfile.lock",
      "db/schema.rb"
    ]
    files = patterns.flat_map { |pattern| Dir.glob(viewer_root.join(pattern).to_s) }.uniq.select { |path| File.file?(path) }.sort
    context_root = output.join("viewer_context")
    rows = []
    files.each do |source_name|
      source = Pathname(source_name)
      relative = source.relative_path_from(viewer_root)
      target = context_root.join(*relative.each_filename.map { |part| DictionaryImport::Support.portable_component(part) })
      FileUtils.mkdir_p(target.dirname)
      FileUtils.cp(source, target, preserve: true)
      row = {
        "kind" => "viewer_context",
        "source_relative_path" => relative.to_s.tr("\\", "/"),
        "snapshot_relative_path" => DictionaryImport::Support.relative(target, output),
        "bytes" => target.size,
        "sha256" => DictionaryImport::Support.sha256(target)
      }
      rows << row
      file_rows << row
    end
    DictionaryImport::Support.write_csv(context_root.join("files.csv"), %w[kind source_relative_path snapshot_relative_path bytes sha256], rows)
  end

  def extract_manifest_rows(viewer_root, output, documents)
    path = viewer_root.join("storage", "corpus_search", "manifest.json.gz")
    return unless path.file?

    wanted_doc_ids = documents.map { |row| row["document_id"].to_s }.to_set
    wanted_work_ids = documents.map { |row| row["work_id"].to_s }.to_set
    raw = Zlib::GzipReader.open(path, &:read)
    payload = JSON.parse(raw)
    rows = Array(payload["documents"]).select do |row|
      wanted_doc_ids.include?((row["id"] || row["document_id"]).to_s) || wanted_work_ids.include?(row["work_id"].to_s)
    end
    DictionaryImport::Support.write_jsonl(output.join("manifest_rows.jsonl"), rows)
  rescue StandardError => error
    warn "[manifest] unable to extract rows: #{error.class}: #{error.message}"
  end

  def git_context(path)
    root = Pathname(path)
    while root.parent != root && !root.join(".git").exist?
      root = root.parent
    end
    return {} unless root.join(".git").exist?
    {
      "repository_root" => root.to_s,
      "head" => `git -C "#{root}" rev-parse HEAD 2>/dev/null`.strip,
      "status_short" => `git -C "#{root}" status --short 2>/dev/null`
    }
  rescue StandardError
    {}
  end

  def problem(kind, request, detail)
    {
      "kind" => kind,
      "configured_title" => request.fetch("title"),
      "category" => request.fetch("category"),
      "detail" => detail
    }
  end

  def readme(summary)
    <<~TEXT
      Dictionary source bundle
      ========================
      Created: #{summary['created_at']}
      Profile: #{summary['profile']}
      Catalogue matches: #{summary['matched_catalogue_items']}/#{summary['configured_works']}
      Distinct copied work folders: #{summary['distinct_copied_work_folders']}
      Copied documents: #{summary['copied_documents']}
      Problems: #{summary['problems']}

      This is an immutable research bundle. It contains complete matched work
      folders, separately indexed declared documents, hashes, metadata, and a
      read-only snapshot of the current Guangyun/dictionary Rails context.

      Nothing in the corpus or Rails database was modified.

      Run the staged dry run from the viewer root:

        bash script/run_dictionary_bundle_dry_run.sh "#{summary['output']}"
    TEXT
  end

  def parse_options(argv)
    options = Options.new(profile: "all", strict: false)
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby script/extract_dictionary_sources.rb --corpus-root PATH [options]"
      opts.on("--corpus-root PATH", "Corpus directory, normally ../corpus") { |value| options.corpus_root = value }
      opts.on("--viewer-root PATH", "Viewer root, default current directory") { |value| options.viewer_root = value }
      opts.on("--output PATH", "Output bundle directory") { |value| options.output = value }
      opts.on("--config PATH", "Named-source catalogue YAML") { |value| options.config = value }
      opts.on("--profile NAME", "all, starter, or a configured profile") { |value| options.profile = value }
      opts.on("--strict", "Exit non-zero if anything is missing or ambiguous") { options.strict = true }
      opts.on("-h", "--help", "Show help") { puts opts; exit 0 }
    end
    parser.parse!(argv)
    abort parser.to_s unless options.corpus_root
    abort "Unexpected arguments: #{argv.join(' ')}" unless argv.empty?
    options
  end
end

exit ExtractDictionarySources.run(ARGV)
