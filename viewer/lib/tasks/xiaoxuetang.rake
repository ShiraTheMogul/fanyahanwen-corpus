# frozen_string_literal: true

build_xiaoxuetang_importer = lambda do |apply:, write_registry:|
  Importers::XiaoxuetangImporter.new(
    zip_path: ENV["ZIP"].presence || Importers::XiaoxuetangImporter::DEFAULT_ZIP_PATH,
    families: ENV["FAMILIES"].presence || ENV["FAMILY"].presence,
    dataset_ids: ENV["DATASETS"].presence || ENV["DATASET"].presence,
    apply: apply,
    replace: ENV["REPLACE"].to_s == "1",
    source: ENV["SOURCE"].presence || Importers::XiaoxuetangImporter::DEFAULT_SOURCE,
    audit_dir: ENV["AUDIT_DIR"].presence,
    registry_path: ENV["REGISTRY"].presence || Importers::XiaoxuetangImporter::DEFAULT_REGISTRY_PATH,
    write_registry: write_registry,
    verbose: ENV.fetch("VERBOSE", "1") == "1"
  )
end

namespace :xiaoxuetang do
  desc "Inspect or import modern Xiaoxuetang pronunciation workbooks from the nested ZIP"
  task import: :environment do
    apply = ENV["APPLY"].to_s == "1"
    replace = ENV["REPLACE"].to_s == "1"

    abort "REPLACE=1 only makes sense with APPLY=1" if replace && !apply

    puts "[xiaoxuetang] No database writes will occur. Add APPLY=1 after reviewing the audit." unless apply

    result = build_xiaoxuetang_importer.call(
      apply: apply,
      write_registry: ENV.fetch("WRITE_REGISTRY", "1") == "1"
    ).run

    puts "[xiaoxuetang] complete #{result.inspect}"
  end

  desc "Rebuild pronunciation locality labels from the nested ZIP without touching the database"
  task sync_registry: :environment do
    result = build_xiaoxuetang_importer.call(
      apply: false,
      write_registry: true
    ).sync_registry!

    puts "[xiaoxuetang] registry complete #{result.inspect}"
  end
end
