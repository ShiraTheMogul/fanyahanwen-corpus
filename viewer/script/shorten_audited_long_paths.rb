#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "optparse"
require "open3"
require "pathname"
require "set"
require "time"
require "unicode_normalize/normalize"
require "yaml"

# Repairs manifest-audited work directories whose physical title component is
# too long for reliable access through WSL/OneDrive.
#
# Two cases are supported:
#   1. A normal JSON work already present in metadata_id_registry.csv: rename the
#      directory and update metadata/registry paths.
#   2. A legacy work skipped by the JSON migration: reserve stable IDs, rename
#      first (so the contents become readable), require exactly one TXT document,
#      convert its leading legacy headers into metadata.json, and write a
#      body-only text.txt.
#
# The script is deliberately plan-first. A normal run only writes review files.
# --apply loads the existing plan, validates all inputs, keeps exact backups, and
# rolls back automatically if any migration or registry update fails.
class AuditedLongPathRepair
  PLAN_VERSION = 2
  DEFAULT_TITLE_CHARS = 36
  EXPECTED_LEGACY_DOCUMENTS = 1
  UTF8_BOM = "\uFEFF"
  CSV_BOM = "\uFEFF"
  SUBPROCESS_UTF8_ENV = { "LANG" => "C.UTF-8", "LC_ALL" => "C.UTF-8" }.freeze

  SINGAPORE_COLLECTIONS = [
    "新加坡漢文/clean/名勝古跡",
    "新加坡漢文/clean/新洲雅苑懷舊集"
  ].freeze

  HEADER_PATTERN = /\A#\s*([^:：]+?)\s*[:：]\s*(.*?)\s*\z/
  UNSAFE_COMPONENT_CHARS = /[<>:"\/\\|?*\u0000-\u001F]/
  RESERVED_WINDOWS_NAMES = /\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?\z/i
  LIST_SPLIT = /[，、；;,|＆&]/

  WORK_LIST_KEYS = {
    "AUTHOR" => "authors",
    "AUTHORS" => "authors",
    "EDITOR" => "editors",
    "EDITORS" => "editors",
    "CATEGORIES" => "categories",
    "CATEGORY" => "categories",
    "IMAGE" => "images",
    "AKA" => "aliases",
    "CONTEXT" => "notes",
    "NOTES" => "notes",
    "CREDIT" => "credits"
  }.freeze

  WORK_SCALAR_KEYS = {
    "WORK_BASE_TITLE" => "work_base_title",
    "LICENSE" => "rights.license",
    "LICENCE" => "rights.license",
    "RIGHTS_NOTE" => "rights.note",
    "EDITION" => "edition",
    "MEDIUM" => "medium",
    "LOCATION" => "location",
    "MODE" => "mode",
    "MOTHER" => "mother",
    "NAME" => "name"
  }.freeze

  IDENTIFIER_KEYS = {
    "ID" => "legacy_id",
    "UNIQUE_ID" => "legacy_unique_id",
    "ENTRY_NUMBER" => "entry_number",
    "CATALOG" => "catalog",
    "MAO_NO" => "mao_no",
    "SOURCE_DB" => "source_db",
    "NO_BRONZE_COMPONENTS" => "no_bronze_components"
  }.freeze

  RegistryInventory = Struct.new(
    :work_ids, :document_ids, :id_owners, :identity_keys, :work_by_path,
    :digest, :headers, keyword_init: true
  )

  def initialize(options)
    @corpus_root = Pathname(options.fetch(:corpus_root)).expand_path
    @audit_path = Pathname(options.fetch(:audit_path)).expand_path
    @id_registry_path = options[:id_registry] && Pathname(options[:id_registry]).expand_path
    @output_root = Pathname(options.fetch(:output_root)).expand_path
    @apply = options.fetch(:apply)
    @replan = options.fetch(:replan)
    @max_title_chars = Integer(options.fetch(:max_title_chars))
    @geography_map_path = Pathname(options.fetch(:geography_map)).expand_path
    @singapore_plan_path = Pathname(options.fetch(:singapore_plan)).expand_path
  end

  def run
    validate_options!
    FileUtils.mkdir_p(@output_root)
    @id_registry_path ||= discover_id_registry
    raise ArgumentError, "No metadata_id_registry.csv found; pass --id-registry PATH" unless @id_registry_path&.file?

    if @apply && !@replan
      plan = load_plan
      validate_plan_before_apply!(plan)
      apply_plan(plan)
    else
      plan = build_plan
      write_plan(plan)
      print_summary(plan)
      return unless @apply

      validate_plan_before_apply!(plan)
      apply_plan(plan)
    end
  end

  private

  def validate_options!
    raise ArgumentError, "Corpus root does not exist: #{@corpus_root}" unless @corpus_root.directory?
    raise ArgumentError, "Manifest audit does not exist: #{@audit_path}" unless @audit_path.file?
    raise ArgumentError, "Geography map does not exist: #{@geography_map_path}" unless @geography_map_path.file?
    raise ArgumentError, "--max-title-chars must be at least 12" if @max_title_chars < 12
  end

  def discover_id_registry
    candidates = Dir.glob(File.expand_path("tmp/corpus_metadata_json/full_*/metadata_id_registry.csv", Dir.pwd))
      .concat(Dir.glob(File.expand_path("tmp/**/metadata_id_registry.csv", Dir.pwd)))
      .uniq
      .map { |path| Pathname(path) }
      .select(&:file?)
    candidates.max_by { |path| [path.mtime.to_i, path.to_s] }
  end

  def load_registry
    work_ids = Set.new
    document_ids = Set.new
    id_owners = {}
    identity_keys = Set.new
    work_by_path = {}
    headers = nil
    count = 0

    CSV.foreach(@id_registry_path, headers: true, encoding: "bom|utf-8") do |row|
      headers ||= row.headers
      kind = row["kind"].to_s
      id = Integer(row["id"], exception: false)
      next unless %w[work document].include?(kind) && id&.positive?

      path = normalize_rel(row["path"])
      identity_key = row["identity_key"].to_s
      owner_key = [kind, id]
      owner = id_owners[owner_key]
      if owner && owner != path
        raise ArgumentError, "Registry ID collision for #{kind} #{id}: #{owner.inspect} and #{path.inspect}"
      end

      id_owners[owner_key] = path
      identity_keys << [kind, identity_key] unless identity_key.empty?
      if kind == "work"
        work_ids << id
        work_by_path[path] = {
          "work_id" => id,
          "path" => path,
          "title" => row["title"].to_s.strip
        } unless path.empty?
      else
        document_ids << id
      end
      count += 1
      warn "[long-paths] registry rows: #{count}" if (count % 25_000).zero?
    end

    headers ||= %w[kind id identity_key path title parent_work_id source_document_id status]
    RegistryInventory.new(
      work_ids: work_ids,
      document_ids: document_ids,
      id_owners: id_owners,
      identity_keys: identity_keys,
      work_by_path: work_by_path,
      digest: Digest::SHA256.file(@id_registry_path).hexdigest,
      headers: headers
    )
  end

  def build_plan
    inventory = load_registry
    supplemental_ids, supplemental_snapshot = collect_supplemental_id_reservations(inventory)
    reservation = collect_external_id_reservation

    reserved_work_ids = inventory.work_ids | supplemental_ids.fetch(:work_ids)
    reserved_document_ids = inventory.document_ids | supplemental_ids.fetch(:document_ids)
    reserved_work_ids << reservation["maximum_work_id"] if reservation["maximum_work_id"].positive?
    reserved_document_ids << reservation["maximum_document_id"] if reservation["maximum_document_id"].positive?

    next_work_id = reserved_work_ids.max.to_i + 1
    next_document_id = reserved_document_ids.max.to_i + 1

    audit_rows = CSV.read(@audit_path, headers: true, encoding: "bom|utf-8")
      .select { |row| row["kind"].to_s == "unreadable_directory" }
      .map { |row| normalize_rel(row["path"]) }
      .uniq

    clean_paths = audit_rows.select { |path| clean_path?(path) }.sort
    raw_paths = audit_rows.select { |path| raw_path?(path) }.sort
    rows = []
    clean_by_title = Hash.new { |hash, key| hash[key] = [] }

    clean_paths.each do |old_rel|
      if SINGAPORE_COLLECTIONS.include?(old_rel)
        rows << skipped_row(old_rel, "folderise_flat_collection", "Handled by folderise_singapore_flat_collections.rb")
        next
      end

      record = inventory.work_by_path[old_rel]
      if record
        planned = planned_existing_json_row(old_rel, record)
      else
        planned = planned_legacy_row(old_rel, next_work_id, next_document_id)
        next_work_id += 1
        next_document_id += EXPECTED_LEGACY_DOCUMENTS
      end
      rows << planned
      clean_by_title[File.basename(old_rel)] << planned
    end

    raw_paths.each do |old_rel|
      matches = clean_by_title[File.basename(old_rel)]
      if matches.length != 1
        rows << skipped_row(old_rel, "raw_pair_ambiguous", "Expected one clean work with the same full title; found #{matches.length}")
        next
      end

      clean = matches.first
      target_rel = File.join(File.dirname(old_rel), File.basename(clean.fetch("new_path"))).tr("\\", "/")
      rows << planned_raw_row(old_rel, target_rel, clean)
    end

    validate_plan_rows!(rows)

    new_legacy_rows = rows.select { |row| row["role"] == "legacy_clean_work_migration" }
    {
      "plan_version" => PLAN_VERSION,
      "created_at" => Time.now.utc.iso8601,
      "corpus_root" => @corpus_root.to_s,
      "audit_path" => @audit_path.to_s,
      "audit_sha256" => Digest::SHA256.file(@audit_path).hexdigest,
      "id_registry" => @id_registry_path.to_s,
      "id_registry_sha256" => inventory.digest,
      "geography_map" => @geography_map_path.to_s,
      "geography_map_sha256" => Digest::SHA256.file(@geography_map_path).hexdigest,
      "max_title_characters" => @max_title_chars,
      "supplemental_id_snapshot" => supplemental_snapshot,
      "external_id_reservation" => reservation,
      "summary" => {
        "audit_unreadable_directories" => audit_rows.length,
        "planned_rows" => rows.count { |row| row["status"] == "planned" },
        "skipped_rows" => rows.count { |row| row["status"] == "skipped" },
        "existing_json_renames" => rows.count { |row| row["role"] == "clean_work" },
        "missed_json_migrations" => new_legacy_rows.length,
        "raw_mirrors" => rows.count { |row| row["role"] == "raw_mirror" },
        "supplemental_work_ids_reserved" => supplemental_ids.fetch(:work_ids).length,
        "supplemental_document_ids_reserved" => supplemental_ids.fetch(:document_ids).length,
        "first_new_work_id" => new_legacy_rows.map { |row| row["work_id"] }.min,
        "last_new_work_id" => new_legacy_rows.map { |row| row["work_id"] }.max,
        "first_new_document_id" => new_legacy_rows.map { |row| row["document_id"] }.min,
        "last_new_document_id" => new_legacy_rows.map { |row| row["document_id"] }.max
      },
      "rows" => rows
    }
  end

  def planned_existing_json_row(old_rel, record)
    title = record.fetch("title").to_s.strip
    title = File.basename(old_rel) if title.empty?
    build_clean_row(
      role: "clean_work",
      old_rel: old_rel,
      title: title,
      work_id: record.fetch("work_id"),
      document_id: nil,
      reason: "manifest_audit_unreadable_directory; exact_registry_path_found"
    )
  end

  def planned_legacy_row(old_rel, work_id, document_id)
    build_clean_row(
      role: "legacy_clean_work_migration",
      old_rel: old_rel,
      title: File.basename(old_rel),
      work_id: work_id,
      document_id: document_id,
      reason: "registry_path_not_found; migrate_single_legacy_document_after_shortening"
    ).merge(
      "expected_txt_documents" => EXPECTED_LEGACY_DOCUMENTS,
      "target_text" => nil
    )
  end

  def build_clean_row(role:, old_rel:, title:, work_id:, document_id:, reason:)
    component = short_component(title, work_id)
    new_rel = File.join(File.dirname(old_rel), component).tr("\\", "/")
    {
      "status" => "planned",
      "role" => role,
      "work_id" => work_id,
      "document_id" => document_id,
      "title" => title,
      "old_path" => old_rel,
      "new_path" => new_rel,
      "old_component_bytes" => File.basename(old_rel).bytesize,
      "new_component_bytes" => component.bytesize,
      "reason" => reason
    }
  end

  def planned_raw_row(old_rel, target_rel, clean)
    {
      "status" => "planned",
      "role" => "raw_mirror",
      "work_id" => clean.fetch("work_id"),
      "document_id" => "",
      "title" => clean.fetch("title"),
      "old_path" => old_rel,
      "new_path" => target_rel,
      "old_component_bytes" => File.basename(old_rel).bytesize,
      "new_component_bytes" => File.basename(target_rel).bytesize,
      "reason" => "paired_to_clean_work"
    }
  end

  def skipped_row(path, reason, message)
    {
      "status" => "skipped",
      "role" => "",
      "work_id" => "",
      "document_id" => "",
      "title" => File.basename(path),
      "old_path" => path,
      "new_path" => "",
      "old_component_bytes" => File.basename(path).bytesize,
      "new_component_bytes" => "",
      "reason" => "#{reason}: #{message}",
      "source_exists" => "",
      "target_exists" => "",
      "blocked" => ""
    }
  end

  def validate_plan_rows!(rows)
    planned = rows.select { |row| row["status"] == "planned" }
    duplicate_targets = planned.group_by { |row| row["new_path"] }.select { |_path, group| group.length > 1 }
    raise ArgumentError, "Target-path collision(s): #{duplicate_targets.keys.join(', ')}" unless duplicate_targets.empty?

    planned.each do |row|
      old_abs = @corpus_root.join(row.fetch("old_path"))
      new_abs = @corpus_root.join(row.fetch("new_path"))
      row["source_exists"] = old_abs.exist?
      row["target_exists"] = new_abs.exist?
      row["blocked"] = !row["source_exists"] || row["target_exists"]
      if row["role"] == "legacy_clean_work_migration"
        begin
          row["legacy_metadata_present"] = old_abs.join("metadata.json").file?
          row["blocked"] = true if row["legacy_metadata_present"]
          row["reason"] += "; unexpected_metadata_json_present" if row["legacy_metadata_present"]
        rescue SystemCallError => error
          # The whole reason for this migration is that directory enumeration may
          # fail before shortening. File.exist? for the known metadata path is a
          # useful hint, but an EIO here does not block the plan by itself.
          row["legacy_metadata_present"] = "unknown: #{error.class}"
        end
      end
    rescue SystemCallError => error
      row["source_exists"] = "unknown"
      row["target_exists"] = "unknown"
      row["blocked"] = true
      row["reason"] = "#{row['reason']}; stat_failed=#{error.class}: #{error.message}"
    end
  end

  def collect_supplemental_id_reservations(inventory)
    work_ids = Set.new
    document_ids = Set.new
    snapshot_parts = []

    SINGAPORE_COLLECTIONS.each do |relative|
      root = @corpus_root.join(relative)
      next unless root.directory?

      Dir.glob(root.join("**", "metadata.json").to_s).sort.each do |path_string|
        path = Pathname(path_string)
        payload = JSON.parse(path.read(encoding: "UTF-8"))
        rel_folder = normalize_rel(path.dirname.relative_path_from(@corpus_root).to_s)
        snapshot_parts << "#{rel_folder}/metadata.json\0#{Digest::SHA256.file(path).hexdigest}"

        work_id = integer_id(payload["work_id"])
        if work_id
          owner = inventory.id_owners[["work", work_id]]
          if owner && owner != rel_folder
            raise ArgumentError, "Installed metadata work ID #{work_id} conflicts with registry path #{owner.inspect} (metadata has #{rel_folder.inspect})"
          end
          work_ids << work_id
        end

        each_metadata_document(payload) do |document|
          document_id = integer_id(document["document_id"])
          document_path = normalize_rel(document["path"])
          next unless document_id

          owner = inventory.id_owners[["document", document_id]]
          if owner && owner != document_path
            raise ArgumentError, "Installed metadata document ID #{document_id} conflicts with registry path #{owner.inspect} (metadata has #{document_path.inspect})"
          end
          document_ids << document_id
        end
      rescue JSON::ParserError, EncodingError, SystemCallError => error
        raise ArgumentError, "Could not read supplemental metadata #{path}: #{error.class}: #{error.message}"
      end
    end

    snapshot = {
      "metadata_files" => snapshot_parts.length,
      "work_ids" => work_ids.length,
      "document_ids" => document_ids.length,
      "sha256" => Digest::SHA256.hexdigest(snapshot_parts.sort.join("\n"))
    }
    [{ work_ids: work_ids, document_ids: document_ids }, snapshot]
  end

  def registry_rows_from_metadata(payload, folder)
    rows = []
    work_id = integer_id(payload["work_id"])
    title = payload["title"].to_s
    if work_id
      rows << registry_row(
        kind: "work", id: work_id, path: folder, title: title,
        parent_work_id: nil, source_document_id: nil
      )
    end

    each_metadata_document(payload) do |document|
      document_id = integer_id(document["document_id"])
      path = normalize_rel(document["path"])
      next unless document_id && !path.empty?

      rows << registry_row(
        kind: "document", id: document_id, path: path,
        title: document["title"].to_s.empty? ? File.basename(path, ".txt") : document["title"].to_s,
        parent_work_id: work_id, source_document_id: nil
      )
    end
    rows
  end

  def each_metadata_document(payload, &block)
    Array(payload["documents"]).each(&block)
    Array(payload["editions"]).each do |edition|
      Array(edition["documents"]).each(&block)
    end
  end

  def collect_external_id_reservation
    return empty_reservation unless @singapore_plan_path.file?

    payload = JSON.parse(@singapore_plan_path.read(encoding: "UTF-8"))
    inventory = payload.fetch("id_inventory", {})
    {
      "source" => @singapore_plan_path.to_s,
      "sha256" => Digest::SHA256.file(@singapore_plan_path).hexdigest,
      "maximum_work_id" => inventory["last_new_work_id"].to_i,
      "maximum_document_id" => inventory["last_new_document_id"].to_i
    }
  rescue JSON::ParserError => error
    raise ArgumentError, "Invalid Singapore plan JSON: #{error.message}"
  end

  def empty_reservation
    { "source" => nil, "sha256" => nil, "maximum_work_id" => 0, "maximum_document_id" => 0 }
  end

  def validate_plan_before_apply!(plan)
    raise ArgumentError, "Unsupported plan version #{plan['plan_version']}" unless plan["plan_version"].to_i == PLAN_VERSION
    raise ArgumentError, "Audit CSV changed after planning; rerun with --replan" unless plan.fetch("audit_sha256") == Digest::SHA256.file(@audit_path).hexdigest
    raise ArgumentError, "ID registry changed after planning; rerun with --replan" unless plan.fetch("id_registry_sha256") == Digest::SHA256.file(@id_registry_path).hexdigest
    raise ArgumentError, "Geography map changed after planning; rerun with --replan" unless plan.fetch("geography_map_sha256") == Digest::SHA256.file(@geography_map_path).hexdigest

    current_inventory = load_registry
    current_supplemental, current_snapshot = collect_supplemental_id_reservations(current_inventory)
    planned_snapshot = plan.fetch("supplemental_id_snapshot")
    unless current_snapshot == planned_snapshot
      raise ArgumentError, "Supplemental installed metadata changed after planning; rerun with --replan"
    end

    reservation = plan.fetch("external_id_reservation")
    if reservation["source"]
      source = Pathname(reservation.fetch("source"))
      unless source.file? && Digest::SHA256.file(source).hexdigest == reservation["sha256"]
        raise ArgumentError, "External ID reservation changed after planning; rerun with --replan"
      end
    end

    planned_rows = plan.fetch("rows").select { |row| row["status"] == "planned" }
    blocked = planned_rows.select { |row| row["blocked"] == true }
    raise ArgumentError, "#{blocked.length} planned operation(s) are blocked; review #{plan_csv_path}" unless blocked.empty?

    planned_rows.each do |row|
      old_abs = @corpus_root.join(row.fetch("old_path"))
      new_abs = @corpus_root.join(row.fetch("new_path"))
      raise ArgumentError, "Source disappeared: #{row['old_path']}" unless old_abs.exist?
      raise ArgumentError, "Target now exists: #{row['new_path']}" if new_abs.exist?
    end

    used_work_ids = current_inventory.work_ids | current_supplemental.fetch(:work_ids)
    used_document_ids = current_inventory.document_ids | current_supplemental.fetch(:document_ids)
    legacy = planned_rows.select { |row| row["role"] == "legacy_clean_work_migration" }
    collisions = legacy.filter do |row|
      used_work_ids.include?(row.fetch("work_id").to_i) || used_document_ids.include?(row.fetch("document_id").to_i)
    end
    unless collisions.empty?
      raise ArgumentError, "Planned stable IDs are now in use; rerun with --replan"
    end
  end

  def apply_plan(plan)
    rows = plan.fetch("rows").select { |row| row["status"] == "planned" }
    clean_rows = rows.select { |row| %w[clean_work legacy_clean_work_migration].include?(row["role"]) }
    raw_rows = rows.select { |row| row["role"] == "raw_mirror" }

    transaction_stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    # Keep backups outside corpus_root so a successful manifest rebuild cannot
    # accidentally index the preserved legacy copies.
    backup_root = @corpus_root.dirname.join(".long_path_repair_backups", transaction_stamp)
    FileUtils.mkdir_p(backup_root)
    applied = []
    migration_reports = []
    new_registry_rows = []
    registry_replaced = false
    registry_backup = backup_root.join("metadata_id_registry.csv.before_long_path_repair")

    begin
      clean_rows.each do |row|
        item = transaction_item(row, backup_root, "clean")
        applied << item
        prepare_materialized_directory!(item)

        working = Pathname(item.fetch("stage"))
        if row["role"] == "legacy_clean_work_migration"
          report, registry_rows = migrate_legacy_single_document!(working, row)
          migration_reports << report
          new_registry_rows.concat(registry_rows)
        else
          update_metadata_paths(working, row.fetch("old_path"), row.fetch("new_path"))
        end

        publish_materialized_directory!(item)
      end

      raw_rows.each do |row|
        item = transaction_item(row, backup_root, "raw")
        applied << item
        prepare_materialized_directory!(item)
        publish_materialized_directory!(item)
      end

      FileUtils.cp(@id_registry_path, registry_backup)
      rewrite_registry!(plan, new_registry_rows)
      registry_replaced = true

      write_migration_report(migration_reports)
      write_rollback(applied, registry_backup)
      @output_root.join("apply_summary.json").write(JSON.pretty_generate({
        "applied_at" => Time.now.utc.iso8601,
        "renamed_directories" => applied.length,
        "migrated_legacy_works" => migration_reports.length,
        "supplemental_work_ids_reserved" => plan.dig("supplemental_id_snapshot", "work_ids"),
        "supplemental_document_ids_reserved" => plan.dig("supplemental_id_snapshot", "document_ids"),
        "new_registry_rows_added" => new_registry_rows.length,
        "backup_root" => backup_root.to_s,
        "directory_copy_method" => windows_mounted_path?(@corpus_root) ? "robocopy" : "ruby_fileutils",
        "rollback_file" => rollback_path.to_s
      }) + "\n", encoding: "UTF-8")
      warn "[long-paths] applied #{applied.length} directory operation(s); migrated #{migration_reports.length} missed JSON work(s)"
      warn "[long-paths] backups retained outside the corpus at #{backup_root}"
    rescue StandardError => error
      warn "[long-paths] ERROR: #{error.class}: #{error.message}; rolling back"
      restore_registry(registry_backup) if registry_replaced && registry_backup.file?
      rollback_filesystem(applied)
      write_rollback(applied, registry_backup)
      raise error.class, "#{error.message}. Changes were rolled back; review #{@output_root}"
    end
  end

  # The failing directories cannot be traversed reliably through Ruby/WSL even
  # after their names are shortened. The safe boundary is therefore:
  #
  #   long path --atomic rename--> short quarantine
  #             --Windows-native copy--> short staging directory
  #             --atomic move--> backup outside corpus_root
  #
  # Ruby only reads the newly materialized staging directory.
  def transaction_item(row, backup_root, kind)
    old_abs = @corpus_root.join(row.fetch("old_path"))
    new_abs = @corpus_root.join(row.fetch("new_path"))
    token = row["work_id"].to_s
    token = Digest::SHA256.hexdigest(row.fetch("old_path"))[0, 12] if token.empty?

    {
      "row" => row,
      "old" => old_abs.to_s,
      "new" => new_abs.to_s,
      "quarantine" => new_abs.dirname.join(".long_path_source__#{kind}__#{token}").to_s,
      "stage" => new_abs.dirname.join(".long_path_stage__#{kind}__#{token}").to_s,
      "backup" => backup_root.join(kind, token).to_s,
      "published" => false
    }
  end

  def prepare_materialized_directory!(item)
    row = item.fetch("row")
    old_abs = Pathname(item.fetch("old"))
    quarantine = Pathname(item.fetch("quarantine"))
    stage = Pathname(item.fetch("stage"))
    backup = Pathname(item.fetch("backup"))

    [quarantine, stage, backup].each do |path|
      raise ArgumentError, "Transaction path already exists: #{path}" if path.exist?
    end

    FileUtils.mkdir_p(quarantine.dirname)
    warn "[long-paths] quarantine #{row.fetch('role')} #{row.fetch('old_path')}"
    File.rename(old_abs, quarantine)

    begin
      copy_directory_materialized!(quarantine, stage)
      verify_materialized_directory!(stage, row)
      FileUtils.mkdir_p(backup.dirname)
      File.rename(quarantine, backup)
    rescue StandardError
      remove_materialized_directory(stage)
      File.rename(quarantine, old_abs) if quarantine.exist? && !old_abs.exist?
      raise
    end
  end

  def publish_materialized_directory!(item)
    row = item.fetch("row")
    stage = Pathname(item.fetch("stage"))
    new_abs = Pathname(item.fetch("new"))
    raise ArgumentError, "Final target already exists: #{row['new_path']}" if new_abs.exist?

    File.rename(stage, new_abs)
    item["published"] = true
    warn "[long-paths] published #{row.fetch('role')} #{row.fetch('new_path')}"
  end

  def copy_directory_materialized!(source, destination)
    if windows_mounted_path?(source) && windows_mounted_path?(destination)
      copy_directory_with_robocopy!(source, destination)
    else
      FileUtils.cp_r(source, destination)
    end
  end

  def copy_directory_with_robocopy!(source, destination)
    source_windows = wsl_to_windows_path(source)
    destination_windows = wsl_to_windows_path(destination)
    attempts = 3
    last_message = nil

    1.upto(attempts) do |attempt|
      remove_materialized_directory(destination)
      stdout, stderr, status = Open3.capture3(
        SUBPROCESS_UTF8_ENV,
        "robocopy.exe",
        source_windows,
        destination_windows,
        "/E", "/COPY:DAT", "/DCOPY:DAT", "/R:2", "/W:1", "/XJ",
        "/NFL", "/NDL", "/NJH", "/NJS", "/NP",
        binmode: true
      )
      code = status.exitstatus
      return if code && code.between?(0, 7)

      last_message = [subprocess_text(stdout), subprocess_text(stderr)].join(" ").strip
      warn "[long-paths] robocopy attempt #{attempt}/#{attempts} failed with exit #{code}: #{last_message}"
      sleep(attempt)
    rescue Errno::ENOENT => error
      raise RuntimeError, "robocopy.exe is unavailable through WSL interop: #{error.message}"
    end

    raise IOError, "robocopy failed after #{attempts} attempts: #{last_message}"
  end

  def wsl_to_windows_path(path)
    stdout, stderr, status = Open3.capture3(
      SUBPROCESS_UTF8_ENV, "wslpath", "-w", path.to_s, binmode: true
    )
    raise IOError, "wslpath failed for #{path}: #{subprocess_text(stderr).strip}" unless status.success?

    converted = subprocess_text(stdout).strip
    raise IOError, "wslpath returned an empty path for #{path}" if converted.empty?

    converted
  end

  def windows_mounted_path?(path)
    path.to_s.match?(%r{\A/mnt/[A-Za-z](?:/|\z)})
  end

  def subprocess_text(bytes)
    bytes.to_s.dup.force_encoding(Encoding::UTF_8).encode(
      Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�"
    )
  end

  def verify_materialized_directory!(destination, row)
    raise IOError, "Materialized directory missing for #{row['old_path']}" unless destination.directory?

    # This is intentionally the first Ruby directory traversal. It happens only
    # against the fresh short-path copy, never against the damaged legacy path.
    Dir.children(destination)
  rescue SystemCallError => error
    raise IOError, "Fresh short-path copy is still unreadable for #{row['old_path']}: #{error.class}: #{error.message}"
  end

  def remove_materialized_directory(path)
    return unless path.exist?

    FileUtils.rm_rf(path)
  rescue SystemCallError => error
    warn "[long-paths] cleanup warning for #{path}: #{error.class}: #{error.message}"
  end

  def migrate_legacy_single_document!(directory, row)
    metadata_path = directory.join("metadata.json")
    raise ArgumentError, "Unexpected metadata.json after rename: #{metadata_path}" if metadata_path.exist?

    txt_paths = Dir.glob(directory.join("**", "*.txt").to_s).map { |path| Pathname(path) }.select(&:file?).sort
    unless txt_paths.length == EXPECTED_LEGACY_DOCUMENTS
      raise ArgumentError, "Expected exactly #{EXPECTED_LEGACY_DOCUMENTS} TXT file in #{row['new_path']}, found #{txt_paths.length}"
    end

    source_path = txt_paths.first
    source_bytes = File.binread(source_path)
    text = source_bytes.dup.force_encoding(Encoding::UTF_8)
    raise Encoding::InvalidByteSequenceError, "Invalid UTF-8 in #{source_path}" unless text.valid_encoding?

    parsed = parse_legacy_text(text)
    body = parsed.fetch(:body)
    raise ArgumentError, "Body is empty after removing legacy headers from #{source_path}" if body.strip.empty?

    target_text = directory.join("text.txt")
    target_rel = normalize_rel("#{row.fetch("new_path")}/text.txt")
    metadata = build_metadata_payload(row, parsed, target_rel)

    text_tmp = directory.join(".text.txt.#{$$}.tmp")
    metadata_tmp = directory.join(".metadata.json.#{$$}.tmp")
    text_tmp.write(body, mode: "w", encoding: "UTF-8")
    metadata_tmp.write(JSON.pretty_generate(metadata) + "\n", mode: "w", encoding: "UTF-8")

    FileUtils.rm_f(target_text) if target_text != source_path
    File.rename(text_tmp, target_text)
    FileUtils.rm_f(source_path) if source_path != target_text
    File.rename(metadata_tmp, metadata_path)

    verify_migrated_work!(directory, row, body)

    report = {
      "work_id" => row.fetch("work_id"),
      "document_id" => row.fetch("document_id"),
      "old_path" => row.fetch("old_path"),
      "new_path" => row.fetch("new_path"),
      "legacy_file" => source_path.basename.to_s,
      "legacy_source_sha256" => Digest::SHA256.hexdigest(source_bytes),
      "header_lines_removed" => parsed.fetch(:header_line_count),
      "unparsed_header_lines" => parsed.fetch(:unparsed_header_lines).length,
      "body_sha256" => Digest::SHA256.hexdigest(body),
      "title" => metadata.fetch("title")
    }

    registry_rows = [
      registry_row(
        kind: "work", id: row.fetch("work_id"), path: row.fetch("new_path"),
        title: metadata.fetch("title"), parent_work_id: nil, source_document_id: nil
      ),
      registry_row(
        kind: "document", id: row.fetch("document_id"), path: target_rel,
        title: metadata.fetch("title"), parent_work_id: row.fetch("work_id"), source_document_id: nil
      )
    ]
    [report, registry_rows]
  ensure
    FileUtils.rm_f(text_tmp) if defined?(text_tmp) && text_tmp
    FileUtils.rm_f(metadata_tmp) if defined?(metadata_tmp) && metadata_tmp
  end

  def parse_legacy_text(text)
    lines = text.delete_prefix(UTF8_BOM).lines
    headers = Hash.new { |hash, key| hash[key] = [] }
    unparsed = []
    index = 0
    header_line_count = 0

    while index < lines.length
      clean = lines[index].chomp
      if clean.start_with?("#")
        if (match = HEADER_PATTERN.match(clean))
          headers[canonical_key(match[1])] << match[2].strip
        else
          unparsed << clean
        end
        index += 1
        header_line_count += 1
        next
      end
      if clean.strip.empty? && header_line_count.positive?
        index += 1
        header_line_count += 1
        next
      end
      break
    end

    {
      headers: headers,
      unparsed_header_lines: unparsed,
      header_line_count: header_line_count,
      body: Array(lines[index..]).join
    }
  end

  def build_metadata_payload(row, parsed, target_rel)
    headers = parsed.fetch(:headers)
    geography = geography_for_path(row.fetch("new_path"))
    title = first_header(headers, "TITLE", "WORK_TITLE")
    title = row.fetch("title") if title.to_s.empty?

    payload = {
      "schema_version" => 1,
      "work_id" => row.fetch("work_id").to_i,
      "corpus_root" => geography["corpus_root"],
      "macro_region" => geography["macro_region"],
      "period" => geography["period"],
      "polity" => geography["polity"],
      "region" => geography["region"],
      "title" => title,
      "authors" => list_header(headers, "AUTHOR", "AUTHORS"),
      "editors" => list_header(headers, "EDITOR", "EDITORS"),
      "contributors" => contributor_headers(headers),
      "categories" => list_header(headers, "CATEGORIES", "CATEGORY"),
      "source_categories" => list_header(headers, "WS_CATEGORIES", "WIKI_CATEGORIES"),
      "sources" => whole_value_headers(headers, "SOURCE", "REFERENCE", "REFERENCES"),
      "identifiers" => identifier_headers(headers),
      "rights" => compact_hash({
        "license" => first_header(headers, "LICENSE", "LICENCE"),
        "note" => first_header(headers, "RIGHTS_NOTE")
      }),
      "work_base_title" => first_header(headers, "WORK_BASE_TITLE"),
      "date_label" => first_header(headers, "YEAR", "DATE"),
      "edition" => first_header(headers, "EDITION"),
      "medium" => first_header(headers, "MEDIUM"),
      "location" => first_header(headers, "LOCATION"),
      "images" => list_header(headers, "IMAGE"),
      "mode" => first_header(headers, "MODE"),
      "mother" => first_header(headers, "MOTHER"),
      "name" => first_header(headers, "NAME"),
      "aliases" => list_header(headers, "AKA"),
      "notes" => list_header(headers, "CONTEXT", "NOTES"),
      "credits" => list_header(headers, "CREDIT"),
      "is_compilation" => false,
      "known_commentaries" => [],
      "contained_in" => [],
      "documents" => [
        compact_hash({
          "document_id" => row.fetch("document_id").to_i,
          "file" => "text.txt",
          "path" => target_rel,
          "title" => first_header(headers, "PAGE_TITLE", "DISPLAY_TITLE", "CHAPTER") || title,
          "page_title" => first_header(headers, "PAGE_TITLE"),
          "display_title" => first_header(headers, "DISPLAY_TITLE"),
          "chapter" => first_header(headers, "CHAPTER"),
          "date_label" => first_header(headers, "YEAR", "DATE"),
          "scraped_at" => first_header(headers, "SCRAPED_AT", "SCRAPED_AT_UTC"),
          "source_categories" => list_header(headers, "WS_CATEGORIES", "WIKI_CATEGORIES"),
          "sources" => whole_value_headers(headers, "SOURCE_URL", "URL")
        })
      ]
    }

    unknown = unknown_legacy_headers(headers)
    unknown["UNPARSED_HEADER_LINES"] = parsed.fetch(:unparsed_header_lines) unless parsed.fetch(:unparsed_header_lines).empty?
    payload["legacy_metadata"] = unknown unless unknown.empty?
    deep_compact(payload)
  end

  def geography_for_path(relative)
    config = YAML.safe_load_file(@geography_map_path, permitted_classes: [], aliases: false)
    rules = config.fetch("rules", {})
    components = normalize_rel(relative).split("/")
    corpus_root = components.first
    geography = {
      "corpus_root" => corpus_root,
      "macro_region" => macro_region_for_root(corpus_root)
    }

    components.each do |component|
      rule = rules[component]
      next unless rule.is_a?(Hash)

      %w[macro_region period polity region].each do |key|
        value = rule[key]
        geography[key] = value unless value.to_s.strip.empty?
      end
    end
    geography
  end

  def macro_region_for_root(root)
    {
      "中國漢文" => "中國",
      "日本漢文" => "日本",
      "朝鮮漢文" => "朝鮮",
      "越南漢文" => "越南",
      "琉球漢文" => "琉球",
      "西域漢文" => "西域",
      "新加坡漢文" => "新加坡"
    }[root]
  end

  def unknown_legacy_headers(headers)
    known = Set.new(
      %w[TITLE WORK_TITLE PAGE_TITLE DISPLAY_TITLE CHAPTER YEAR DATE SCRAPED_AT SCRAPED_AT_UTC
         SOURCE SOURCE_URL URL REFERENCE REFERENCES NATION TIMES REGION ARTIST CALLIGRAPHER AUTHOR_PAGE] +
      WORK_LIST_KEYS.keys + WORK_SCALAR_KEYS.keys + IDENTIFIER_KEYS.keys +
      %w[WS_CATEGORIES WIKI_CATEGORIES]
    )
    headers.each_with_object({}) do |(key, values), output|
      output[key] = values if !known.include?(key) && values.any?
    end
  end

  def contributor_headers(headers)
    rows = []
    list_header(headers, "ARTIST").each { |name| rows << { "role" => "artist", "name" => name } }
    list_header(headers, "CALLIGRAPHER").each { |name| rows << { "role" => "calligrapher", "name" => name } }
    rows.uniq
  end

  def identifier_headers(headers)
    IDENTIFIER_KEYS.flat_map do |key, scheme|
      whole_value_headers(headers, key).map { |value| { "scheme" => scheme, "value" => value } }
    end.uniq
  end

  def list_header(headers, *keys)
    keys.flat_map { |key| Array(headers[key]) }
      .flat_map { |value| value.to_s.split(LIST_SPLIT) }
      .map(&:strip).reject(&:empty?).uniq
  end

  def whole_value_headers(headers, *keys)
    keys.flat_map { |key| Array(headers[key]) }.map(&:strip).reject(&:empty?).uniq
  end

  def first_header(headers, *keys)
    whole_value_headers(headers, *keys).first
  end

  def canonical_key(value)
    value.to_s.strip.upcase.gsub(/[[:space:]\-]+/, "_").gsub(/[^[:alnum:]_]/, "_").gsub(/_+/, "_").delete_prefix("_").delete_suffix("_")
  end

  def verify_migrated_work!(directory, row, expected_body)
    metadata = JSON.parse(directory.join("metadata.json").read(encoding: "UTF-8"))
    raise "work_id verification failed" unless metadata["work_id"].to_i == row.fetch("work_id").to_i
    document = Array(metadata["documents"]).first
    raise "document_id verification failed" unless document && document["document_id"].to_i == row.fetch("document_id").to_i
    text = directory.join("text.txt").read(encoding: "UTF-8")
    raise "body checksum verification failed" unless Digest::SHA256.hexdigest(text) == Digest::SHA256.hexdigest(expected_body)
    txt_files = Dir.glob(directory.join("**", "*.txt").to_s)
    raise "expected one body TXT after migration, found #{txt_files.length}" unless txt_files.length == 1
  end

  def update_metadata_paths(directory, old_rel, new_rel)
    Dir.glob(directory.join("**", "metadata.json").to_s).each do |path_string|
      path = Pathname(path_string)
      payload = JSON.parse(path.read(encoding: "UTF-8"))
      changed = replace_prefixes(payload, old_rel, new_rel)
      next unless changed

      tmp = path.dirname.join(".metadata.json.#{$$}.tmp")
      tmp.write(JSON.pretty_generate(payload) + "\n", encoding: "UTF-8")
      File.rename(tmp, path)
    ensure
      FileUtils.rm_f(tmp) if defined?(tmp) && tmp
    end
  end

  def replace_prefixes(object, old_rel, new_rel)
    changed = false
    case object
    when Hash
      object.each do |key, value|
        if value.is_a?(String) && (value == old_rel || value.start_with?(old_rel + "/"))
          object[key] = new_rel + value.delete_prefix(old_rel)
          changed = true
        else
          changed = replace_prefixes(value, old_rel, new_rel) || changed
        end
      end
    when Array
      object.each_with_index do |value, index|
        if value.is_a?(String) && (value == old_rel || value.start_with?(old_rel + "/"))
          object[index] = new_rel + value.delete_prefix(old_rel)
          changed = true
        else
          changed = replace_prefixes(value, old_rel, new_rel) || changed
        end
      end
    end
    changed
  end

  def rewrite_registry!(plan, new_rows)
    path_updates = plan.fetch("rows").select { |row| row["role"] == "clean_work" }.to_h do |row|
      [row.fetch("old_path"), row.fetch("new_path")]
    end
    additions = new_rows

    temp = @id_registry_path.dirname.join(".#{@id_registry_path.basename}.#{$$}.tmp")
    seen_ids = Set.new
    seen_identity = Set.new
    headers = CSV.open(@id_registry_path, "r:bom|utf-8", &:first)
    headers = Array(headers)
    headers = %w[kind id identity_key path title parent_work_id source_document_id status] if headers.empty?

    CSV.open(temp, "wb", row_sep: "\n") do |csv|
      csv << headers
      CSV.foreach(@id_registry_path, headers: true, encoding: "bom|utf-8") do |row|
        kind = row["kind"].to_s
        old_path = normalize_rel(row["path"])
        replacement = matching_path_update(old_path, path_updates)
        if replacement
          row["path"] = replacement
          row["identity_key"] = kind == "work" ? "work:#{replacement}" : "document:#{replacement}" if %w[work document].include?(kind)
        end
        csv << headers.map { |header| row[header] }
        seen_ids << [kind, integer_id(row["id"])]
        seen_identity << [kind, row["identity_key"].to_s]
      end

      headers ||= %w[kind id identity_key path title parent_work_id source_document_id status]
      additions.each do |row|
        id_key = [row.fetch("kind"), integer_id(row.fetch("id"))]
        identity_key = [row.fetch("kind"), row.fetch("identity_key")]
        next if seen_ids.include?(id_key) || seen_identity.include?(identity_key)

        csv << headers.map { |header| row[header] }
        seen_ids << id_key
        seen_identity << identity_key
      end
    end

    File.rename(temp, @id_registry_path)
  ensure
    FileUtils.rm_f(temp) if defined?(temp) && temp
  end

  def matching_path_update(path, updates)
    updates.each do |old_rel, new_rel|
      return new_rel + path.delete_prefix(old_rel) if path == old_rel || path.start_with?(old_rel + "/")
    end
    nil
  end

  def registry_row(kind:, id:, path:, title:, parent_work_id:, source_document_id:)
    {
      "kind" => kind,
      "id" => id,
      "identity_key" => "#{kind}:#{path}",
      "path" => path,
      "title" => title,
      "parent_work_id" => parent_work_id,
      "source_document_id" => source_document_id,
      "status" => "active"
    }
  end

  def restore_registry(backup)
    FileUtils.cp(backup, @id_registry_path)
  end

  def rollback_filesystem(applied)
    applied.reverse_each do |item|
      row = item.fetch("row")
      old_abs = Pathname(item.fetch("old"))
      new_abs = Pathname(item.fetch("new"))
      stage = Pathname(item.fetch("stage"))
      quarantine = Pathname(item.fetch("quarantine"))
      backup = Pathname(item.fetch("backup"))

      remove_materialized_directory(new_abs)
      remove_materialized_directory(stage)
      FileUtils.mkdir_p(old_abs.dirname)

      if backup.exist? && !old_abs.exist?
        File.rename(backup, old_abs)
      elsif quarantine.exist? && !old_abs.exist?
        File.rename(quarantine, old_abs)
      end
    rescue StandardError => rollback_error
      warn "[long-paths] rollback warning for #{row['new_path']}: #{rollback_error.class}: #{rollback_error.message}"
    end
  end

  def write_rollback(applied, registry_backup)
    lines = ["#!/usr/bin/env bash", "set -euo pipefail", ""]
    lines << "cp #{shell_quote(registry_backup.to_s)} #{shell_quote(@id_registry_path.to_s)}" if registry_backup
    applied.reverse_each do |item|
      old_abs = Pathname(item.fetch("old"))
      new_abs = Pathname(item.fetch("new"))
      stage = Pathname(item.fetch("stage"))
      quarantine = Pathname(item.fetch("quarantine"))
      backup = Pathname(item.fetch("backup"))
      lines << "rm -rf #{shell_quote(new_abs.to_s)} #{shell_quote(stage.to_s)}"
      lines << "mkdir -p #{shell_quote(old_abs.dirname.to_s)}"
      lines << "if test -e #{shell_quote(backup.to_s)}; then mv #{shell_quote(backup.to_s)} #{shell_quote(old_abs.to_s)}; elif test -e #{shell_quote(quarantine.to_s)}; then mv #{shell_quote(quarantine.to_s)} #{shell_quote(old_abs.to_s)}; fi"
    end
    rollback_path.write(lines.join("\n") + "\n", encoding: "UTF-8")
    FileUtils.chmod(0o755, rollback_path)
  end

  def write_migration_report(rows)
    write_csv_with_bom(migration_report_path, rows)
  end

  def write_plan(plan)
    plan_path.write(JSON.pretty_generate(plan) + "\n", encoding: "UTF-8")
    write_csv_with_bom(plan_csv_path, plan.fetch("rows"))
    @output_root.join("summary.json").write(JSON.pretty_generate(plan.fetch("summary")) + "\n", encoding: "UTF-8")
  end

  def write_csv_with_bom(path, rows)
    headers = rows.flat_map(&:keys).uniq
    File.open(path, "wb") do |io|
      io.write(CSV_BOM.encode(Encoding::UTF_8))
      csv = CSV.new(io, write_headers: true, headers: headers, row_sep: "\r\n")
      rows.each { |row| csv << headers.map { |header| row[header] } }
      csv.close
    end
  end

  def load_plan
    JSON.parse(plan_path.read(encoding: "UTF-8"))
  rescue Errno::ENOENT
    raise ArgumentError, "No reviewed plan exists at #{plan_path}; run once without --apply first"
  rescue JSON::ParserError => error
    raise ArgumentError, "Invalid plan JSON: #{error.message}"
  end

  def print_summary(plan)
    summary = plan.fetch("summary")
    warn "[long-paths] planned=#{summary.fetch('planned_rows')} skipped=#{summary.fetch('skipped_rows')}"
    warn "[long-paths] missed JSON migrations=#{summary.fetch('missed_json_migrations')} raw mirrors=#{summary.fetch('raw_mirrors')}"
    warn "[long-paths] new work IDs #{summary['first_new_work_id']}..#{summary['last_new_work_id']}" if summary["first_new_work_id"]
    warn "[long-paths] new document IDs #{summary['first_new_document_id']}..#{summary['last_new_document_id']}" if summary["first_new_document_id"]
    warn "[long-paths] reserved installed metadata IDs: works=#{summary.fetch('supplemental_work_ids_reserved')} documents=#{summary.fetch('supplemental_document_ids_reserved')}"
    warn "[long-paths] review #{plan_csv_path}"
  end

  def short_component(title, work_id)
    clean = title.to_s.unicode_normalize(:nfc)
      .gsub(UNSAFE_COMPONENT_CHARS, "-")
      .gsub(/[[:space:]]+/, " ")
      .strip
      .sub(/[. ]+\z/, "")
    clean = "work" if clean.empty? || clean.match?(RESERVED_WINDOWS_NAMES)
    graphemes = clean.each_grapheme_cluster.to_a
    clean = graphemes.first(@max_title_chars - 1).join + "…" if graphemes.length > @max_title_chars
    component = "#{clean}__w#{work_id}"
    raise ArgumentError, "Generated component exceeds 180 UTF-8 bytes: #{component}" if component.bytesize > 180
    component
  end

  def clean_path?(path) = path.split("/").include?("clean")
  def raw_path?(path) = path.split("/").include?("raw")
  def integer_id(value) = Integer(value, exception: false)&.then { |id| id.positive? ? id : nil }
  def normalize_rel(value) = value.to_s.tr("\\", "/").sub(%r{\A/+}, "").sub(%r{/+\z}, "")

  def compact_hash(hash)
    hash.each_with_object({}) do |(key, value), output|
      next if value.nil? || value == "" || (value.respond_to?(:empty?) && value.empty?)
      output[key] = value
    end
  end

  def deep_compact(object)
    case object
    when Hash
      object.each_with_object({}) do |(key, value), output|
        compacted = deep_compact(value)
        next if compacted.nil? || compacted == "" || (compacted.respond_to?(:empty?) && compacted.empty?)
        output[key] = compacted
      end
    when Array
      object.map { |value| deep_compact(value) }.reject { |value| value.nil? || value == "" || (value.respond_to?(:empty?) && value.empty?) }
    else
      object
    end
  end

  def shell_quote(value) = "'#{value.to_s.gsub("'", %q('"'"'))}'"
  def plan_path = @output_root.join("plan.json")
  def plan_csv_path = @output_root.join("long_path_plan.csv")
  def migration_report_path = @output_root.join("migrated_legacy_works.csv")
  def rollback_path = @output_root.join("ROLLBACK.sh")
end

if $PROGRAM_NAME == __FILE__
  options = {
    corpus_root: ENV["CORPUS_ROOT"].to_s.empty? ? File.expand_path("../corpus", Dir.pwd) : ENV["CORPUS_ROOT"],
    audit_path: File.expand_path("tmp/corpus_search_manifest_audit/manifest_scan_issues.csv", Dir.pwd),
    id_registry: nil,
    output_root: File.expand_path("tmp/long_path_repair", Dir.pwd),
    geography_map: File.expand_path("config/corpus_metadata/geography_period_map.yml", Dir.pwd),
    singapore_plan: File.expand_path("tmp/singapore_folderisation/plan.json", Dir.pwd),
    apply: false,
    replan: false,
    max_title_chars: AuditedLongPathRepair::DEFAULT_TITLE_CHARS
  }

  parser = OptionParser.new do |opts|
    opts.banner = "Usage: bundle exec ruby script/shorten_audited_long_paths.rb [options]"
    opts.on("--corpus-root PATH", "Live corpus root") { |value| options[:corpus_root] = value }
    opts.on("--audit PATH", "manifest_scan_issues.csv") { |value| options[:audit_path] = value }
    opts.on("--id-registry PATH", "Authoritative metadata_id_registry.csv") { |value| options[:id_registry] = value }
    opts.on("--output PATH", "Plan/report directory") { |value| options[:output_root] = value }
    opts.on("--geography-map PATH", "geography_period_map.yml") { |value| options[:geography_map] = value }
    opts.on("--singapore-plan PATH", "Prior Singapore plan used as an ID reservation") { |value| options[:singapore_plan] = value }
    opts.on("--max-title-chars N", Integer, "Physical title prefix length") { |value| options[:max_title_chars] = value }
    opts.on("--replan", "Build a new plan before apply") { options[:replan] = true }
    opts.on("--apply", "Apply the existing reviewed plan") { options[:apply] = true }
    opts.on("-h", "--help") { puts opts; exit }
  end
  parser.parse!
  AuditedLongPathRepair.new(options).run
end
