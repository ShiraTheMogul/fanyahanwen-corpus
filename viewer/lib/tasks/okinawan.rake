# frozen_string_literal: true

namespace :okinawan do
  desc "Inspect or import single-character Okinawan (Uchinaaguchi, Shuri) readings from 沖繩語辞典"
  task import: :environment do
    apply = ENV["APPLY"].to_s == "1"
    replace = ENV["REPLACE"].to_s == "1"

    abort "REPLACE=1 only makes sense with APPLY=1" if replace && !apply

    puts "[okinawan] No database writes will occur. Add APPLY=1 after reviewing the audit." unless apply

    result = Importers::OkinawanUchinaaguchiImporter.new(
      main_path: ENV["MAIN"].presence || Importers::OkinawanUchinaaguchiImporter::DEFAULT_MAIN_PATH,
      index_path: ENV["INDEX"].presence || Importers::OkinawanUchinaaguchiImporter::DEFAULT_INDEX_PATH,
      apply: apply,
      replace: replace,
      source: ENV["SOURCE"].presence || Importers::OkinawanUchinaaguchiImporter::DEFAULT_SOURCE,
      audit_dir: ENV["AUDIT_DIR"].presence,
      verbose: ENV.fetch("VERBOSE", "1") == "1"
    ).run

    puts "[okinawan] complete #{result.inspect}"
  end
end
