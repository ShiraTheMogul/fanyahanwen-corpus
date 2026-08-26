# frozen_string_literal: true

require "pathname"

namespace :corpus_metadata_dates do
  desc "Audit automatic metadata dating without changing corpus files"
  task audit: :environment do
    run_metadata_dater(apply: false, apply_moves: false, merge_duplicates: false)
  end

  desc "Write date/ca metadata derived by the automatic dating pass; does not move works"
  task apply: :environment do
    run_metadata_dater(apply: true, apply_moves: false, merge_duplicates: false)
  end

  desc "Write chronology and move clearly future-misfiled works; MERGE_DUPLICATES=1 enables strict duplicate replacement"
  task apply_moves: :environment do
    run_metadata_dater(
      apply: true,
      apply_moves: true,
      merge_duplicates: ENV["MERGE_DUPLICATES"].to_s == "1"
    )
  end

  def run_metadata_dater(apply:, apply_moves:, merge_duplicates:)
    root = Pathname(Rails.configuration.x.corpus_root).realpath
    result = CorpusMetadataAutoDater.new(
      root: root,
      apply: apply,
      apply_moves: apply_moves,
      merge_duplicates: merge_duplicates,
      future_margin: Integer(ENV.fetch("FUTURE_MARGIN", "25")),
      progress_every: Integer(ENV.fetch("PROGRESS_EVERY", "1000")),
      path_filter: ENV["PATH_FILTER"],
      limit: ENV["LIMIT"],
      report_root: ENV["REPORT_ROOT"]
    ).run!

    mode = apply ? "APPLY" : "AUDIT"
    puts "#{mode}: #{result.scanned} metadata files scanned."
    puts "  exact self/regnal dates: #{result.dated}"
    puts "  author-derived ca:       #{result.circa_author}"
    puts "  polity-derived ca:       #{result.circa_polity}"
    puts "  unchanged:               #{result.unchanged}"
    puts "  future move candidates:  #{result.move_candidates}"
    puts "  moved:                    #{result.moved}"
    puts "  duplicate candidates:    #{result.duplicate_candidates}"
    puts "  merged:                   #{result.merged}"
    puts "Reports: #{result.report_dir}"
    puts "Rebuild the corpus manifest after applying changes: bin/rails corpus_search:rebuild_manifest" if apply
  end
  desc "Audit safe rows from a completed dates.tsv checkpoint without rescanning corpus texts"
  task checkpoint_audit: :environment do
    run_metadata_date_checkpoint(apply: false)
  end

  desc "Apply safe rows from a completed dates.tsv checkpoint; self-regnal rows remain deferred"
  task checkpoint_apply: :environment do
    run_metadata_date_checkpoint(apply: true)
  end

  def run_metadata_date_checkpoint(apply:)
    root = Pathname(Rails.configuration.x.corpus_root).realpath
    report = metadata_date_checkpoint_report
    result = CorpusMetadataDateCheckpointApplier.new(
      root: root,
      report_path: report,
      apply: apply,
      progress_every: Integer(ENV.fetch("PROGRESS_EVERY", "5000")),
      path_filter: ENV["PATH_FILTER"],
      report_root: ENV["REPORT_ROOT"]
    ).run!

    mode = apply ? "CHECKPOINT APPLY" : "CHECKPOINT AUDIT"
    puts "#{mode}: #{result.rows} report rows read."
    puts "  safe candidates:          #{result.eligible}"
    puts "  would write:              #{result.would_write}" unless apply
    puts "  written:                  #{result.written}" if apply
    puts "  already chronologized:    #{result.already_chronologized}"
    puts "  self-regnal deferred:     #{result.deferred_self_regnal}"
    puts "  author/path rejected:     #{result.author_path_rejected}"
    puts "  author/path unknown:      #{result.author_path_unknown}"
    puts "  folder ca overrides:      #{result.folder_overrides}"
    puts "  folder/report conflicts:  #{result.folder_conflicts}"
    puts "  period metadata repairs:  #{result.period_repairs}"
    puts "  polity metadata repairs:  #{result.polity_repairs}"
    puts "  folder repair unknown:    #{result.folder_repair_unknown}"
    puts "  stale report rows:        #{result.stale}"
    puts "  missing metadata:         #{result.missing}"
    puts "  errors:                   #{result.errors}"
    puts "Review: #{result.report_dir}"
    puts "Rebuild the corpus manifest after applying changes: bin/rails corpus_search:rebuild_manifest" if apply
  end

  def metadata_date_checkpoint_report
    explicit = ENV["REPORT"].to_s.strip
    return Pathname(explicit).expand_path if explicit.present?

    reports = Dir.glob(Rails.root.join("tmp", "corpus_metadata_auto_dates", "*", "dates.tsv").to_s).sort
    raise "No completed dates.tsv report found; set REPORT=/path/to/dates.tsv" if reports.empty?

    Pathname(reports.last)
  end

end
