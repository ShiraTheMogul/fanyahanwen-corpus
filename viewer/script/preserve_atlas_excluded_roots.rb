#!/usr/bin/env ruby
# encoding: UTF-8
# frozen_string_literal: true

require "fileutils"
require "json"
require "optparse"
require "pathname"
require "time"

Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8

module PreserveAtlasExcludedRoots
  module_function

  REQUIRED_ROOTS = %w[他漢文 西域漢文].freeze

  Options = Struct.new(:apply, :repo_root, keyword_init: true)

  def run(argv)
    options = parse_options(argv)
    repo_root = Pathname.new(options.repo_root || Dir.pwd).expand_path
    rules_path = repo_root.join("script", "atlas_node_type_rules.json")
    rectifier_path = repo_root.join("script", "rectify_atlas_node_types.rb")
    periodisation_path = repo_root.join("content", "atlas", "periodisation.json")

    [rules_path, rectifier_path, periodisation_path].each do |path|
      abort_with("Missing required file: #{path}") unless path.file?
    end

    rules = read_json(rules_path)
    periodisation = read_json(periodisation_path)
    rectifier = rectifier_path.binread.force_encoding(Encoding::UTF_8)
    abort_with("Invalid UTF-8: #{rectifier_path}") unless rectifier.valid_encoding?

    updated_rules = add_excluded_roots(rules)
    updated_rectifier = patch_rectifier(rectifier)

    current_periodisation_roots = Array(periodisation["excluded_corpus_roots"]).map(&:to_s)
    missing_live = REQUIRED_ROOTS - current_periodisation_roots
    abort_with("Current periodisation.json is missing excluded roots: #{missing_live.join(', ')}") if missing_live.any?
    western_region = Array(periodisation["macro_regions"]).find { |row| row["id"].to_s == "西域" }
    abort_with("Current periodisation.json still publishes a 西域 macro-region") if western_region

    changes = []
    changes << rules_path if JSON.pretty_generate(rules) != JSON.pretty_generate(updated_rules)
    changes << rectifier_path if rectifier != updated_rectifier

    puts "Atlas excluded-root safeguard — #{options.apply ? 'APPLY' : 'DRY RUN'}"
    puts "Current Atlas already excludes: #{current_periodisation_roots.join(', ')}"
    puts "Files needing change: #{changes.length}"
    changes.each { |path| puts "  - #{path.relative_path_from(repo_root)}" }

    if changes.empty?
      puts "Nothing to change. The live Atlas and regeneration rules are already safe."
      return 0
    end

    unless options.apply
      puts "Dry run only. Rerun with --apply."
      return 0
    end

    backup_root = repo_root.join("tmp", "atlas_excluded_root_safeguard", Time.now.utc.strftime("%Y%m%dT%H%M%SZ"))
    FileUtils.mkdir_p(backup_root)

    backup_and_write(repo_root, backup_root, rules_path, JSON.pretty_generate(updated_rules) + "\n") if changes.include?(rules_path)
    backup_and_write(repo_root, backup_root, rectifier_path, updated_rectifier) if changes.include?(rectifier_path)

    reparsed_rules = read_json(rules_path)
    missing_rules = REQUIRED_ROOTS - Array(reparsed_rules["excluded_corpus_roots"]).map(&:to_s)
    raise "Rules update failed: #{missing_rules.join(', ')}" if missing_rules.any?
    source = rectifier_path.binread.force_encoding(Encoding::UTF_8)
    unless source.include?('"excluded_corpus_roots" => Array(rules["excluded_corpus_roots"])')
      raise "Rectifier update verification failed"
    end

    puts "Applied successfully. Backup: #{backup_root}"
    puts "Next commands:"
    puts "  ruby -c script/rectify_atlas_node_types.rb"
    puts "  bin/rails atlas:rebuild_catalogue"
    puts "  bin/rails atlas:verify"
    0
  end

  def parse_options(argv)
    options = Options.new(apply: false)
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby script/preserve_atlas_excluded_roots.rb [--dry-run|--apply] [--repo PATH]"
      opts.on("--dry-run", "Show changes without writing (default)") { options.apply = false }
      opts.on("--apply", "Back up and apply the two regeneration safeguards") { options.apply = true }
      opts.on("--repo PATH", "Viewer repository root; defaults to current directory") { |value| options.repo_root = value }
      opts.on("-h", "--help", "Show help") do
        puts opts
        exit 0
      end
    end
    parser.parse!(argv)
    abort_with("Unexpected arguments: #{argv.join(' ')}") unless argv.empty?
    options
  end

  def add_excluded_roots(rules)
    roots = (Array(rules["excluded_corpus_roots"]).map(&:to_s) + REQUIRED_ROOTS).reject(&:empty?).uniq
    output = {}
    inserted = false
    rules.each do |key, value|
      output[key] = value
      next unless key == "macro_regions"
      output["excluded_corpus_roots"] = roots
      inserted = true
    end
    output["excluded_corpus_roots"] = roots unless inserted
    output
  end

  def patch_rectifier(source)
    marker = '"excluded_corpus_roots" => Array(rules["excluded_corpus_roots"])'
    return source if source.include?(marker)

    abort_with("Could not locate rewrite_periodisation! in rectifier") unless source.include?("  def rewrite_periodisation!(atlas_root, rules)\n")

    old = "      end\n    }\n    atomic_write_json(atlas_root.join(\"periodisation.json\"), payload)"
    new = "      end,\n      \"excluded_corpus_roots\" => Array(rules[\"excluded_corpus_roots\"]).map(&:to_s).reject(&:empty?).uniq\n    }\n    atomic_write_json(atlas_root.join(\"periodisation.json\"), payload)"

    occurrences = source.scan(Regexp.new(Regexp.escape(old))).length
    unless occurrences == 1
      abort_with("Expected one recognised periodisation payload ending; found #{occurrences}. Refusing to edit it")
    end

    source.sub(old, new)
  end

  def backup_and_write(repo_root, backup_root, path, content)
    relative = path.relative_path_from(repo_root)
    backup = backup_root.join(relative)
    FileUtils.mkdir_p(backup.dirname)
    FileUtils.copy_file(path, backup, true)
    atomic_write(path, content)
  end

  def read_json(path)
    text = path.binread.force_encoding(Encoding::UTF_8)
    raise "Invalid UTF-8 JSON: #{path}" unless text.valid_encoding?
    JSON.parse(text.sub(/\A\uFEFF/, ""))
  end

  def atomic_write(path, content)
    temp = path.dirname.join(".#{path.basename}.tmp-#{Process.pid}")
    File.open(temp, "wb") do |file|
      file.write(content.encode(Encoding::UTF_8))
      file.flush
      file.fsync
    end
    File.rename(temp, path)
  ensure
    FileUtils.rm_f(temp) if defined?(temp) && temp&.exist?
  end

  def abort_with(message)
    warn message
    exit 2
  end
end

exit PreserveAtlasExcludedRoots.run(ARGV)
