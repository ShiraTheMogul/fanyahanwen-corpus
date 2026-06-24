# frozen_string_literal: true

namespace :corpus_activity do
  desc "Build paged latest-text and recent-change feeds from the cached corpus manifest"
  task rebuild: :environment do
    manifest = CorpusSearch::Manifest.load
    activity = CorpusActivity::SnapshotBuilder.new(manifest: manifest).build!

    puts "Built corpus activity feeds."
    puts "Latest text folders: #{activity.dig("feeds", "latest_texts", "total")}"
    puts "Recent changed files: #{activity.dig("feeds", "recent_changes", "total")}"
  end
end
