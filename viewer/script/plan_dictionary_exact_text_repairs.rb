#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "yaml"

module PlanDictionaryExactTextRepairs
  module_function

  HEADERS = %w[
    repair_id document_id source_relative_path source_line original_line replacement_line
    status applied live_sha256 backup_path witness_url witness_reading reason
  ].freeze

  def run(argv)
    options = { config: "config/dictionary_import/wuyin_jiyun_text_repairs.yml", apply: false }
    OptionParser.new do |opts|
      opts.on("--bundle PATH") { |v| options[:bundle] = v }
      opts.on("--corpus-root PATH") { |v| options[:corpus_root] = v }
      opts.on("--output PATH") { |v| options[:output] = v }
      opts.on("--config PATH") { |v| options[:config] = v }
      opts.on("--apply") { options[:apply] = true }
    end.parse!(argv)

    %i[bundle corpus_root output].each { |key| abort "Missing --#{key.to_s.tr('_', '-')}" unless options[key] }
    bundle = Pathname(options[:bundle]).expand_path
    corpus_root = Pathname(options[:corpus_root]).expand_path
    output = Pathname(options[:output]).expand_path
    config = YAML.safe_load(Pathname(options[:config]).read(encoding: "UTF-8"), aliases: false)
    repairs = Array(config["repairs"])
    documents = CSV.read(bundle.join("documents.csv"), headers: true, encoding: "bom|utf-8").map(&:to_h)
    docs = documents.to_h { |row| [row.fetch("document_id").to_i, row] }

    FileUtils.rm_rf(output)
    FileUtils.mkdir_p(output.join("backups"))
    rows = []
    file_plans = {}

    repairs.each do |repair|
      document = docs[repair.fetch("document_id").to_i]
      unless document
        rows << result_row(repair, nil, "document_not_in_bundle")
        next
      end

      snapshot = bundle.join(document.fetch("snapshot_relative_path"))
      live = corpus_root.join(document.fetch("source_relative_path"))
      unless snapshot.file? && live.file?
        rows << result_row(repair, document, snapshot.file? ? "live_file_missing" : "snapshot_file_missing")
        next
      end

      snapshot_lines = snapshot.read(encoding: "UTF-8").lines
      live_lines = live.read(encoding: "UTF-8").lines
      line_index = repair.fetch("source_line").to_i - 1
      expected_original_text = repair.fetch("original_line")
      expected_replacement_text = repair.fetch("replacement_line")

      unless line_index.between?(0, snapshot_lines.length - 1) && snapshot_lines[line_index].chomp == expected_original_text
        rows << result_row(repair, document, "snapshot_line_guard_failed", live)
        next
      end
      unless snapshot_lines.length == live_lines.length
        rows << result_row(repair, document, "live_line_count_changed", live)
        next
      end

      allowed_indexes = repairs.select { |r| r.fetch("document_id").to_i == repair.fetch("document_id").to_i }
        .map { |r| r.fetch("source_line").to_i - 1 }
      changed_elsewhere = snapshot_lines.each_index.any? do |i|
        next false if allowed_indexes.include?(i)
        snapshot_lines[i] != live_lines[i]
      end
      if changed_elsewhere
        rows << result_row(repair, document, "live_file_changed_outside_configured_lines", live)
        next
      end

      current = live_lines[line_index]
      newline = current.end_with?("\r\n") ? "\r\n" : "\n"
      expected_original = expected_original_text + newline
      expected_replacement = expected_replacement_text + newline
      status = if current.chomp == expected_original_text
                 "ready_to_apply"
               elsif current.chomp == expected_replacement_text
                 "already_applied"
               else
                 "live_line_guard_failed"
               end
      row = result_row(repair, document, status, live)
      rows << row
      if %w[ready_to_apply already_applied].include?(status)
        plan = (file_plans[live.to_s] ||= { path: live, lines: live_lines, rows: [] })
        plan[:rows] << [row, line_index, expected_replacement]
      end
    end

    blockers = rows.count { |r| !%w[ready_to_apply already_applied].include?(r["status"]) }
    if options[:apply] && blockers.positive?
      write_outputs(output, rows, options[:apply])
      abort "Refusing to apply: #{blockers} blocker(s)"
    end

    if options[:apply]
      file_plans.each_value do |plan|
        changed = plan[:rows].any? { |row, _i, _value| row["status"] == "ready_to_apply" }
        next unless changed

        backup = output.join("backups", plan[:path].relative_path_from(corpus_root))
        FileUtils.mkdir_p(backup.dirname)
        FileUtils.cp(plan[:path], backup)
        proposed = plan[:lines].dup
        plan[:rows].each { |_row, i, value| proposed[i] = value }
        temp = Pathname("#{plan[:path]}.tmp-#{Process.pid}")
        temp.write(proposed.join, encoding: "UTF-8")
        File.rename(temp, plan[:path])
        abort "Verification failed: #{plan[:path]}" unless plan[:path].read(encoding: "UTF-8").lines == proposed
        plan[:rows].each do |row, _i, _value|
          next unless row["status"] == "ready_to_apply"
          row["status"] = "applied_to_corpus_txt"
          row["applied"] = true
          row["backup_path"] = backup.to_s
        end
      end
    end

    write_outputs(output, rows, options[:apply])
  end

  def result_row(repair, document, status, live = nil)
    {
      "repair_id" => repair["repair_id"],
      "document_id" => repair["document_id"],
      "source_relative_path" => document && document["source_relative_path"],
      "source_line" => repair["source_line"],
      "original_line" => repair["original_line"],
      "replacement_line" => repair["replacement_line"],
      "status" => status,
      "applied" => false,
      "live_sha256" => live&.file? ? Digest::SHA256.file(live).hexdigest : nil,
      "backup_path" => nil,
      "witness_url" => repair["witness_url"],
      "witness_reading" => repair["witness_reading"],
      "reason" => repair["reason"]
    }
  end

  def write_outputs(output, rows, apply)
    CSV.open(output.join("text_repair_plan.csv"), "wb", write_headers: true, headers: HEADERS, force_quotes: true) do |csv|
      rows.each { |row| csv << HEADERS.map { |h| row[h] } }
    end
    summary = {
      "mode" => apply ? "apply" : "dry_run",
      "configured" => rows.length,
      "ready_to_apply" => rows.count { |r| r["status"] == "ready_to_apply" },
      "already_applied" => rows.count { |r| r["status"] == "already_applied" },
      "applied" => rows.count { |r| r["applied"] },
      "blocked" => rows.count { |r| !%w[ready_to_apply already_applied applied_to_corpus_txt].include?(r["status"]) },
      "metadata_files_modified" => 0,
      "database_writes" => 0
    }
    output.join("summary.json").write(JSON.pretty_generate(summary) + "\n", encoding: "UTF-8")
    output.join("summary.txt").write(summary.map { |k, v| "#{k}: #{v}" }.join("\n") + "\n", encoding: "UTF-8")
    puts summary.inspect
  end
end

PlanDictionaryExactTextRepairs.run(ARGV)
