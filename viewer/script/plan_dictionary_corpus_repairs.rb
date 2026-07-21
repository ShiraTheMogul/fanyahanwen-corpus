#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "yaml"

module PlanDictionaryCorpusRepairs
  module_function

  Options = Struct.new(:bundle, :corpus_root, :output, :config, :apply, keyword_init: true)
  APPROVED_DECISIONS = %w[approved_for_corpus_repair approved_for_import_layer].freeze
  HEADERS = %w[
    repair_id dictionary_title document_id source_relative_path snapshot_relative_path
    snapshot_sha256 live_sha256 restored_headword fanqie source_line_start
    insertion_line original_line proposed_line status applied backup_path
    witness_label witness_url note
  ].freeze

  def run(argv)
    options = parse_options(argv)
    bundle = Pathname(options.bundle).expand_path
    corpus_root = options.corpus_root && Pathname(options.corpus_root).expand_path
    output = Pathname(options.output || bundle.join("corpus_repair_plan")).expand_path
    config_path = Pathname(options.config || "config/dictionary_import/source_comparison_repairs.yml").expand_path
    documents_path = bundle.join("documents.csv")

    abort "Missing bundle documents.csv: #{documents_path}" unless documents_path.file?
    abort "Missing repair config: #{config_path}" unless config_path.file?
    abort "--corpus-root is required for this repair cycle" unless corpus_root
    abort "Corpus root not found: #{corpus_root}" unless corpus_root.directory?

    documents = CSV.read(documents_path, headers: true, encoding: "bom|utf-8").map(&:to_h)
    docs_by_id = documents.to_h { |row| [row["document_id"].to_i, row] }
    config = YAML.safe_load(config_path.read(encoding: "UTF-8"), aliases: false) || {}
    repairs = Array(config["repairs"]).select { |row| APPROVED_DECISIONS.include?(row["decision"].to_s) }

    FileUtils.rm_rf(output)
    FileUtils.mkdir_p(output.join("backups"))

    planned_documents = []
    rows = []

    repairs.group_by { |repair| repair.fetch("document_id").to_i }.sort.each do |document_id, document_repairs|
      document = docs_by_id[document_id]
      unless document
        document_repairs.each do |repair|
          rows << base_row(repair).merge("status" => "document_not_in_bundle", "applied" => false)
        end
        next
      end

      snapshot_path = bundle.join(document.fetch("snapshot_relative_path"))
      live_path = corpus_root.join(document.fetch("source_relative_path"))
      unless snapshot_path.file?
        document_repairs.each do |repair|
          rows << base_row(repair, document).merge("status" => "snapshot_file_missing", "applied" => false)
        end
        next
      end
      unless live_path.file?
        document_repairs.each do |repair|
          rows << base_row(repair, document).merge("status" => "live_corpus_file_missing", "applied" => false)
        end
        next
      end

      snapshot_sha = Digest::SHA256.file(snapshot_path).hexdigest
      declared_sha = document.fetch("sha256")
      if snapshot_sha != declared_sha
        document_repairs.each do |repair|
          rows << base_row(repair, document).merge(
            "snapshot_sha256" => snapshot_sha,
            "status" => "snapshot_hash_mismatch",
            "applied" => false
          )
        end
        next
      end

      snapshot_lines = snapshot_path.read(encoding: "UTF-8").lines
      live_lines = live_path.read(encoding: "UTF-8").lines
      live_sha = Digest::SHA256.file(live_path).hexdigest

      locations = []
      document_repairs.each do |repair|
        location = locate_repair(snapshot_lines, repair)
        unless location
          rows << base_row(repair, document).merge(
            "snapshot_sha256" => snapshot_sha,
            "live_sha256" => live_sha,
            "status" => "guarded_insertion_point_not_found_in_snapshot",
            "applied" => false
          )
          next
        end
        locations << [repair, location]
      end
      next unless locations.length == document_repairs.length

      if locations.map { |_repair, location| location.fetch(:line_index) }.uniq.length != locations.length
        locations.each do |repair, location|
          rows << base_row(repair, document).merge(
            "snapshot_sha256" => snapshot_sha,
            "live_sha256" => live_sha,
            "insertion_line" => location.fetch(:line_index) + 1,
            "status" => "multiple_repairs_target_same_line",
            "applied" => false
          )
        end
        next
      end

      comparison = compare_live_to_allowed_states(snapshot_lines, live_lines, locations)
      unless comparison.fetch(:safe)
        locations.each do |repair, location|
          rows << base_row(repair, document).merge(
            "snapshot_sha256" => snapshot_sha,
            "live_sha256" => live_sha,
            "insertion_line" => location.fetch(:line_index) + 1,
            "original_line" => location.fetch(:original_line).chomp,
            "proposed_line" => location.fetch(:proposed_line).chomp,
            "status" => "live_file_changed_outside_approved_repairs",
            "applied" => false
          )
        end
        next
      end

      proposed_live_lines = live_lines.dup
      document_rows = []
      locations.each do |repair, location|
        index = location.fetch(:line_index)
        current_line = live_lines[index]
        status = if current_line == location.fetch(:proposed_line)
                   "already_applied"
                 elsif current_line == location.fetch(:original_line)
                   proposed_live_lines[index] = location.fetch(:proposed_line)
                   "ready_to_apply"
                 else
                   "live_line_not_in_allowed_state"
                 end

        document_rows << base_row(repair, document).merge(
          "snapshot_sha256" => snapshot_sha,
          "live_sha256" => live_sha,
          "insertion_line" => index + 1,
          "original_line" => location.fetch(:original_line).chomp,
          "proposed_line" => location.fetch(:proposed_line).chomp,
          "status" => status,
          "applied" => false
        )
      end

      rows.concat(document_rows)
      planned_documents << {
        document: document,
        live_path: live_path,
        live_lines: live_lines,
        proposed_lines: proposed_live_lines,
        rows: document_rows
      }
    end

    blockers = rows.count { |row| !%w[ready_to_apply already_applied].include?(row["status"]) }
    if options.apply && blockers.positive?
      write_outputs(output, rows, repairs.length, options.apply)
      abort "Refusing to apply: #{blockers} blocker(s). Review #{output.join('corpus_repair_plan.csv')}"
    end

    if options.apply
      planned_documents.each do |planned|
        next if planned.fetch(:live_lines) == planned.fetch(:proposed_lines)

        document = planned.fetch(:document)
        live_path = planned.fetch(:live_path)
        backup_path = output.join("backups", document.fetch("source_relative_path"))
        FileUtils.mkdir_p(backup_path.dirname)
        FileUtils.cp(live_path, backup_path)
        atomic_write(live_path, planned.fetch(:proposed_lines).join)

        unless live_path.read(encoding: "UTF-8").lines == planned.fetch(:proposed_lines)
          abort "Post-write verification failed: #{live_path}"
        end

        planned.fetch(:rows).each do |row|
          if row["status"] == "ready_to_apply"
            row["status"] = "applied_to_corpus_txt"
            row["applied"] = true
            row["backup_path"] = backup_path.to_s
          end
        end
      end
    end

    write_outputs(output, rows, repairs.length, options.apply)
  end

  def locate_repair(lines, repair)
    source_line_index = repair.fetch("source_line_start").to_i - 1
    return nil unless source_line_index.between?(0, lines.length - 1)

    fanqie = repair.fetch("fanqie").to_s
    payload_probe = Array(lines[source_line_index, 5]).join.gsub(/\s+/, "")
    return nil unless payload_probe.start_with?("〈#{fanqie}")

    lower = [source_line_index - 8, 0].max
    (source_line_index - 1).downto(lower) do |index|
      line = lines[index]
      next unless line

      marker = line.rindex("○")
      next unless marker
      next unless line[(marker + 1)..].to_s.strip.empty?

      proposed = line.dup.insert(marker + 1, repair.fetch("restored_headword").to_s)
      return {
        line_index: index,
        original_line: line,
        proposed_line: proposed
      }
    end
    nil
  end

  def compare_live_to_allowed_states(snapshot_lines, live_lines, locations)
    return { safe: false, reason: "line_count_changed" } unless snapshot_lines.length == live_lines.length

    allowed = locations.to_h do |_repair, location|
      [location.fetch(:line_index), [location.fetch(:original_line), location.fetch(:proposed_line)]]
    end

    snapshot_lines.each_index do |index|
      live = live_lines[index]
      if allowed.key?(index)
        return { safe: false, reason: "repair_line_changed" } unless allowed.fetch(index).include?(live)
      else
        return { safe: false, reason: "other_line_changed" } unless live == snapshot_lines[index]
      end
    end
    { safe: true }
  end

  def write_outputs(output, rows, configured_count, apply_mode)
    CSV.open(output.join("corpus_repair_plan.csv"), "wb", write_headers: true, headers: HEADERS, force_quotes: true) do |csv|
      rows.each { |row| csv << HEADERS.map { |header| row[header] } }
    end

    summary = {
      "mode" => apply_mode ? "apply" : "dry_run",
      "configured_repairs" => configured_count,
      "ready_to_apply" => rows.count { |row| row["status"] == "ready_to_apply" },
      "already_applied" => rows.count { |row| row["status"] == "already_applied" },
      "applied" => rows.count { |row| row["applied"] },
      "blocked" => rows.count { |row| !%w[ready_to_apply already_applied applied_to_corpus_txt].include?(row["status"]) },
      "metadata_files_modified" => 0,
      "database_rows_written" => 0
    }
    output.join("summary.json").write(JSON.pretty_generate(summary) + "\n", encoding: "UTF-8")
    output.join("summary.txt").write(summary_text(summary), encoding: "UTF-8")
    puts JSON.pretty_generate(summary)
    puts "Output: #{output}"
  end

  def parse_options(argv)
    options = Options.new(apply: false)
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ruby script/plan_dictionary_corpus_repairs.rb --bundle DIR --corpus-root DIR [options]"
      opts.on("--bundle DIR", "Captured source bundle used for the reviewed dry run") { |value| options.bundle = value }
      opts.on("--corpus-root DIR", "Live corpus root") { |value| options.corpus_root = value }
      opts.on("--output DIR", "Process report and backup directory") { |value| options.output = value }
      opts.on("--config FILE", "Approved comparison repair register") { |value| options.config = value }
      opts.on("--apply", "Apply exact guarded repairs to corpus TXT files") { options.apply = true }
      opts.on("-h", "--help", "Show help") { puts opts; exit 0 }
    end
    parser.parse!(argv)
    abort parser.to_s unless options.bundle && options.corpus_root
    abort "Unexpected arguments: #{argv.join(' ')}" unless argv.empty?
    options
  end

  def base_row(repair, document = nil)
    {
      "repair_id" => repair["repair_id"],
      "dictionary_title" => repair["dictionary_title"],
      "document_id" => repair["document_id"],
      "source_relative_path" => document && document["source_relative_path"],
      "snapshot_relative_path" => document && document["snapshot_relative_path"],
      "restored_headword" => repair["restored_headword"],
      "fanqie" => repair["fanqie"],
      "source_line_start" => repair["source_line_start"],
      "witness_label" => repair["witness_label"],
      "witness_url" => repair["witness_url"],
      "note" => repair["note"]
    }
  end

  def summary_text(summary)
    <<~TEXT
      HONGWU CORPUS TXT REPAIR
      ========================
      Mode:                       #{summary['mode']}
      Configured repairs:         #{summary['configured_repairs']}
      Ready to apply:             #{summary['ready_to_apply']}
      Already applied:            #{summary['already_applied']}
      Applied in this run:        #{summary['applied']}
      Blocked:                    #{summary['blocked']}
      Metadata files modified:    #{summary['metadata_files_modified']}
      Database rows written:      #{summary['database_rows_written']}
    TEXT
  end

  def atomic_write(path, content)
    path = Pathname(path)
    temporary = path.dirname.join(".#{path.basename}.tmp-#{Process.pid}")
    File.open(temporary, "wb") { |io| io.write(content) }
    File.rename(temporary, path)
  ensure
    FileUtils.rm_f(temporary) if defined?(temporary) && temporary
  end
end

PlanDictionaryCorpusRepairs.run(ARGV) if $PROGRAM_NAME == __FILE__
