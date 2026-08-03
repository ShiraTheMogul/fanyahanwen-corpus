# frozen_string_literal: true

require "pathname"

namespace :corpus_metadata_ids do
  desc "Repair missing and duplicate metadata IDs in place"
  task repair: :environment do
    corpus_root = Pathname(Rails.configuration.x.corpus_root).realpath
    registry_path = Pathname(
      ENV.fetch("CORPUS_METADATA_ID_REGISTRY", corpus_root.join(".metadata_id_registry.csv").to_s)
    ).expand_path
    output_root = Rails.root.join("tmp", "corpus_metadata_ids")

    seed_registry_paths = []
    explicit_seed = ENV["CORPUS_METADATA_ID_SEED_REGISTRY"].to_s.strip
    seed_registry_paths << Pathname(explicit_seed).expand_path unless explicit_seed.empty?
    seed_registry_paths.concat(
      Dir.glob(Rails.root.join("tmp", "corpus_metadata_json", "**", "metadata_id_registry.csv").to_s)
        .map { |path| Pathname(path) }
        .select(&:file?)
        .sort_by { |path| -path.mtime.to_f }
        .first(1)
    )

    result = CorpusMetadataIdReconciler.new(
      root: corpus_root,
      registry_path: registry_path,
      output_root: output_root,
      seed_registry_paths: seed_registry_paths,
      logger: Rails.logger,
      progress_every: Integer(ENV.fetch("CORPUS_METADATA_ID_PROGRESS_EVERY", "10000"))
    ).run!

    puts "Metadata IDs ready: #{result.assigned_ids} assigned, " \
      "#{result.reassigned_conflicts} duplicate claims reassigned, " \
      "#{result.added_document_records} document records added, " \
      "#{result.created_metadata_files} metadata files created, " \
      "#{result.changed_metadata_files} metadata files written."
    puts "Metadata ID registry: #{registry_path}"
    puts "Metadata ID report: #{result.report_path}"
  end
end

# Rake merges task definitions, so this prerequisite is retained whether this
# file is loaded before or after corpus_search.rake. The repair therefore runs
# before every normal manifest rebuild without replacing the rebuild task.
task "corpus_search:rebuild_manifest" => "corpus_metadata_ids:repair"
