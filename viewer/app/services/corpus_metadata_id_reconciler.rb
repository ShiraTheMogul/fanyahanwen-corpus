# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "pathname"
require "set"
require "time"

class CorpusMetadataIdReconciler
  REGISTRY_HEADERS = %w[
    kind id identity_key path title parent_work_id source_document_id status
  ].freeze
  SKIP_NAMES = %w[.git .svn node_modules tmp log storage bak vendor].freeze
  Result = Data.define(
    :assigned_ids,
    :reassigned_conflicts,
    :changed_metadata_files,
    :created_metadata_files,
    :added_document_records,
    :registry_rows,
    :report_path
  )

  Entity = Struct.new(
    :kind,
    :identity_key,
    :path,
    :title,
    :parent_key,
    :id,
    :references,
    keyword_init: true
  )

  MetadataRecord = Struct.new(
    :path,
    :relative_path,
    :directory,
    :payload,
    :created,
    :changed,
    keyword_init: true
  )

  attr_reader :root, :registry_path, :output_root

  def initialize(root:, registry_path:, output_root:, seed_registry_paths: [], logger: nil,
                 progress_every: 10_000, backup: true)
    @root = Pathname(File.realpath(root.to_s))
    @registry_path = Pathname(registry_path).expand_path
    @output_root = Pathname(output_root).expand_path
    @seed_registry_paths = Array(seed_registry_paths).map { |path| Pathname(path).expand_path }
    @logger = logger
    @progress_every = progress_every.to_i
    @backup = backup

    @metadata_records = []
    @metadata_by_dir = {}
    @text_paths = []
    @entities = {
      "work" => {},
      "document" => {},
      "edition" => {}
    }
    @registry_rows = []
    @registry_by_identity = {}
    @changes = []
    @scan_issues = []
    @assigned_ids = 0
    @reassigned_conflicts = 0
    @created_metadata_files = 0
    @added_document_records = 0
  end

  def run!
    FileUtils.mkdir_p(@output_root)
    lock_path = @output_root.join("metadata_id_repair.lock")
    FileUtils.mkdir_p(lock_path.dirname)

    File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
      lock.flock(File::LOCK_EX)
      run_locked!
    end
  end

  private

  def run_locked!
    started_at = Time.now.utc
    load_registry!
    walk_corpus!
    raise_incomplete_scan!
    load_metadata!
    ensure_searchable_documents!
    reconcile_ids!
    update_worklist_references!
    changed_metadata_files = write_changes!
    registry_content = build_registry_content
    write_registry!(registry_content)
    report_path = write_reports!(started_at)

    Result.new(
      assigned_ids: @assigned_ids,
      reassigned_conflicts: @reassigned_conflicts,
      changed_metadata_files: changed_metadata_files,
      created_metadata_files: @created_metadata_files,
      added_document_records: @added_document_records,
      registry_rows: @registry_rows.length,
      report_path: report_path.to_s
    )
  end

  def load_registry!
    candidates = [@registry_path, *@seed_registry_paths].select(&:file?)
    candidates.each do |path|
      CSV.foreach(path, headers: true, encoding: "bom|utf-8") do |row|
        kind = row["kind"].to_s.strip
        id = positive_integer(row["id"])
        identity = row["identity_key"].to_s.strip
        next unless @entities.key?(kind) && id && !identity.empty?

        normalized = REGISTRY_HEADERS.to_h { |header| [header, row[header].to_s] }
        normalized["id"] = id.to_s
        @registry_by_identity[[kind, identity]] ||= normalized
      end
    rescue CSV::MalformedCSVError, SystemCallError => error
      @scan_issues << {
        "kind" => "registry_read_error",
        "path" => path.to_s,
        "error_class" => error.class.name,
        "message" => error.message
      }
    end
  end

  def walk_corpus!
    stack = [@root]
    visited = 0

    until stack.empty?
      directory = stack.pop
      safe_children(directory).each do |name|
        next if name.start_with?(".") && name != ".metadata_id_registry.csv"
        next if SKIP_NAMES.include?(name)

        path = directory.join(name)
        stat = File.lstat(path)
        next if stat.symlink?

        if stat.directory?
          stack << path
        elsif stat.file?
          if name == "metadata.json"
            @metadata_records << path
          elsif name.downcase.end_with?(".txt")
            @text_paths << path
          end
        end
      rescue Errno::ENOENT, Errno::EACCES, Errno::EIO, Encoding::CompatibilityError => error
        @scan_issues << {
          "kind" => "unreadable_entry",
          "path" => relative_display(path),
          "error_class" => error.class.name,
          "message" => error.message
        }
      end

      visited += 1
      progress("corpus walk: #{visited} directories visited") if progress_tick?(visited)
    end

    @metadata_records.sort_by! { |path| relative_path(path) }
    @text_paths.sort_by! { |path| relative_path(path) }
    progress("corpus walk found #{@metadata_records.length} metadata files and #{@text_paths.length} TXT files")
  end

  def safe_children(directory)
    attempts = 0
    begin
      attempts += 1
      Dir.children(directory).sort
    rescue Errno::ENOENT, Errno::EACCES, Errno::EIO, Encoding::CompatibilityError => error
      if attempts < 3
        sleep(0.25 * attempts)
        retry
      end
      @scan_issues << {
        "kind" => "unreadable_directory",
        "path" => relative_display(directory),
        "error_class" => error.class.name,
        "message" => error.message
      }
      []
    end
  end

  def raise_incomplete_scan!
    serious = @scan_issues.select { |issue| issue["kind"].start_with?("unreadable_") }
    return if serious.empty?

    write_scan_issue_report
    raise "Metadata ID repair could not inspect the complete corpus. Review #{@output_root.join('metadata_id_scan_issues.csv')}"
  end

  def load_metadata!
    paths = @metadata_records
    @metadata_records = []

    paths.each do |path|
      payload = parse_metadata(path)
      next unless payload

      register_metadata_record(path, payload, created: false)
    end
  end

  def parse_metadata(path)
    payload = JSON.parse(path.read(encoding: "bom|utf-8"))
    raise JSON::ParserError, "top-level metadata value is not an object" unless payload.is_a?(Hash)

    payload
  rescue JSON::ParserError, SystemCallError => error
    @scan_issues << {
      "kind" => "invalid_metadata",
      "path" => relative_display(path),
      "error_class" => error.class.name,
      "message" => error.message
    }
    nil
  end

  def register_metadata_record(path, payload, created:)
    record = MetadataRecord.new(
      path: path,
      relative_path: relative_path(path),
      directory: path.dirname,
      payload: payload,
      created: created,
      changed: created
    )
    @metadata_records << record
    @metadata_by_dir[fs_key(path.dirname)] = record
    register_owned_entities!(record)
    record
  end

  def register_owned_entities!(metadata)
    folder = relative_path(metadata.directory)
    work = entity_for(
      "work",
      "work:#{folder}",
      path: folder,
      title: first_present(metadata.payload["title"], metadata.directory.basename.to_s),
      parent_key: nil
    )
    add_record_reference(work, metadata.payload, "work_id", metadata)

    Array(metadata.payload["documents"]).each_with_index do |document, index|
      register_document!(metadata, document, ["documents", index]) if document.is_a?(Hash)
    end

    Array(metadata.payload["editions"]).each_with_index do |edition, edition_index|
      next unless edition.is_a?(Hash)

      edition_key = "edition:#{folder}:#{edition_index}"
      edition_entity = entity_for(
        "edition",
        edition_key,
        path: edition_key,
        title: first_present(edition["title"], edition["edition_label"], "Edition #{edition_index + 1}"),
        parent_key: work.identity_key
      )
      add_record_reference(edition_entity, edition, "edition_id", metadata)
      Array(edition["documents"]).each_with_index do |document, document_index|
        register_document!(metadata, document, ["editions", edition_index, "documents", document_index]) if document.is_a?(Hash)
      end
    end

    Array(metadata.payload["translations"]).each_with_index do |translation, translation_index|
      next unless translation.is_a?(Hash)

      Array(translation["documents"]).each_with_index do |document, document_index|
        register_document!(metadata, document, ["translations", translation_index, "documents", document_index]) if document.is_a?(Hash)
      end
    end
  end

  def register_document!(metadata, document, location)
    path = resolved_document_path(metadata, document, location)
    return unless path

    normalize_document_locator!(metadata, document, path)
    work_key = "work:#{relative_path(metadata.directory)}"
    entity = entity_for(
      "document",
      "document:#{path}",
      path: path,
      title: first_present(document["title"], File.basename(path, ".txt")),
      parent_key: work_key
    )
    add_record_reference(entity, document, "document_id", metadata)
  end

  def resolved_document_path(metadata, document, location)
    explicit = document["path"].to_s.strip
    file = document["file"].to_s.strip
    candidate = if !explicit.empty?
      normalize_relative(explicit)
    elsif !file.empty?
      normalize_relative(File.join(relative_path(metadata.directory), file))
    else
      nil
    end

    if candidate.nil? || candidate.empty?
      @scan_issues << {
        "kind" => "document_locator_missing",
        "path" => metadata.relative_path,
        "error_class" => "",
        "message" => location.join("/")
      }
      return nil
    end

    candidate
  rescue ArgumentError => error
    @scan_issues << {
      "kind" => "unsafe_document_path",
      "path" => metadata.relative_path,
      "error_class" => error.class.name,
      "message" => error.message
    }
    nil
  end

  def normalize_document_locator!(metadata, document, path)
    changed = false
    if document["path"].to_s != path
      document["path"] = path
      changed = true
    end
    if document["file"].to_s.empty?
      document["file"] = File.basename(path)
      changed = true
    end
    mark_changed(metadata) if changed
  end

  def ensure_searchable_documents!
    @text_paths.each_with_index do |absolute, index|
      relative = relative_path(absolute)
      next unless searchable_role?(relative)
      next if @entities["document"].key?("document:#{relative}")

      metadata = metadata_for_unowned_text(absolute, relative)
      document = {
        "file" => absolute.basename.to_s,
        "path" => relative
      }
      metadata.payload["documents"] = Array(metadata.payload["documents"])
      metadata.payload["documents"] << document
      mark_changed(metadata)
      @added_document_records += 1
      register_document!(metadata, document, ["documents", metadata.payload["documents"].length - 1])

      progress("document ownership: #{index + 1}/#{@text_paths.length}") if progress_tick?(index + 1)
    end
  end

  def searchable_role?(relative)
    if defined?(CorpusSearch::DocumentRole)
      CorpusSearch::DocumentRole.searchable?(CorpusSearch::DocumentRole.classify(relative))
    else
      !relative.split("/").map(&:downcase).include?("raw")
    end
  end

  def metadata_for_unowned_text(absolute, _relative)
    direct = @metadata_by_dir[fs_key(absolute.dirname)]
    return direct if direct

    # Match CorpusMetadataStore: the nearest metadata ancestor owns nested text
    # unless the text directory has its own metadata. This keeps one work intact
    # while still giving every nested text a distinct document ID.
    ancestor = nearest_metadata_ancestor(absolute.dirname)
    return ancestor if ancestor

    create_minimal_metadata!(absolute.dirname)
  end

  def nearest_metadata_ancestor(directory)
    current = directory
    loop do
      metadata = @metadata_by_dir[fs_key(current)]
      return metadata if metadata
      break if current == @root
      break unless current.to_s.start_with?(@root.to_s + File::SEPARATOR)

      current = current.parent
    end
    nil
  end

  def create_minimal_metadata!(directory)
    existing = @metadata_by_dir[fs_key(directory)]
    return existing if existing

    path = directory.join("metadata.json")
    relative = relative_path(directory)
    payload = {
      "schema_version" => 1,
      "title" => directory.basename.to_s,
      "corpus_root" => relative.split("/").first.to_s,
      "documents" => []
    }
    record = register_metadata_record(path, payload, created: true)
    @created_metadata_files += 1
    @changes << {
      "action" => "create_metadata",
      "kind" => "work",
      "old_id" => "",
      "new_id" => "",
      "path" => relative,
      "metadata_path" => record.relative_path
    }
    record
  end

  def reconcile_ids!
    %w[work edition document].each do |kind|
      entities = @entities.fetch(kind).values.sort_by(&:identity_key)
      normalize_same_entity_ids!(kind, entities)
      resolve_duplicate_ids!(kind, entities)
      assign_missing_ids!(kind, entities)
      write_entity_ids!(kind, entities)
    end
  end

  def normalize_same_entity_ids!(kind, entities)
    entities.each do |entity|
      ids = entity.references.filter_map { |ref| positive_integer(ref[:container][ref[:key]]) }.uniq
      next if ids.length <= 1

      preferred = registry_candidate(entity)&.fetch("id", nil).to_i
      preferred = ids.min unless ids.include?(preferred)
      entity.id = preferred
      ids.each do |old_id|
        next if old_id == preferred

        @reassigned_conflicts += 1
        change_row("same_entity_conflict", kind, old_id, preferred, entity.path, first_metadata_path(entity))
      end
    end
  end

  def resolve_duplicate_ids!(kind, entities)
    groups = Hash.new { |hash, key| hash[key] = [] }
    entities.each do |entity|
      entity.id ||= entity.references.filter_map { |ref| positive_integer(ref[:container][ref[:key]]) }.first
      groups[entity.id] << entity if entity.id
    end

    used = groups.keys.compact.to_set
    next_id = used.max.to_i + 1
    groups.each do |id, claimants|
      next if claimants.length <= 1

      registry_owner = claimants.find { |entity| positive_integer(registry_candidate(entity)&.fetch("id", nil)) == id }
      keeper = registry_owner || claimants.min_by(&:identity_key)
      (claimants - [keeper]).sort_by(&:identity_key).each do |entity|
        next_id += 1 while used.include?(next_id)
        old_id = entity.id
        entity.id = next_id
        used << next_id
        @reassigned_conflicts += 1
        change_row("duplicate_id_reassigned", kind, old_id, next_id, entity.path, first_metadata_path(entity))
        next_id += 1
      end
    end
  end

  def assign_missing_ids!(kind, entities)
    used = entities.filter_map(&:id).to_set
    registry_ids_for(kind).each { |id| used << id }
    next_id = used.max.to_i + 1

    entities.each do |entity|
      next if entity.id

      registry_id = positive_integer(registry_candidate(entity)&.fetch("id", nil))
      if registry_id && !used.include?(registry_id)
        entity.id = registry_id
      else
        next_id += 1 while used.include?(next_id)
        entity.id = next_id
        next_id += 1
      end
      used << entity.id
      @assigned_ids += 1
      change_row("assign_missing_id", kind, "", entity.id, entity.path, first_metadata_path(entity))
    end
  end

  def write_entity_ids!(kind, entities)
    entities.each do |entity|
      entity.references.each do |reference|
        container = reference.fetch(:container)
        key = reference.fetch(:key)
        old = positive_integer(container[key])
        next if old == entity.id

        container[key] = entity.id
        mark_changed(reference.fetch(:metadata))
        change_row("write_id", kind, old || "", entity.id, entity.path, reference.fetch(:metadata).relative_path)
      end
    end
  end

  def update_worklist_references!
    work_ids = @entities["work"].values.to_h { |entity| [entity.identity_key, entity.id] }
    document_ids = @entities["document"].values.to_h { |entity| [entity.identity_key, entity.id] }

    @metadata_records.each do |metadata|
      walk = lambda do |value|
        case value
        when Hash
          if value.key?("path")
            path = normalize_relative(value["path"])
            work_key = "work:#{path}"
            document_key = "document:#{path}"
            if work_ids.key?(work_key) && positive_integer(value["work_id"]) != work_ids[work_key]
              value["work_id"] = work_ids[work_key]
              mark_changed(metadata)
            end
            if document_ids.key?(document_key) && positive_integer(value["document_id"]) != document_ids[document_key]
              value["document_id"] = document_ids[document_key]
              mark_changed(metadata)
            end
          end
          value.each_value { |child| walk.call(child) }
        when Array
          value.each { |child| walk.call(child) }
        end
      end
      walk.call(metadata.payload["worklist"])
      walk.call(metadata.payload["contained_in"])
    end
  end

  def entity_for(kind, identity_key, path:, title:, parent_key:)
    @entities.fetch(kind)[identity_key] ||= Entity.new(
      kind: kind,
      identity_key: identity_key,
      path: path,
      title: title.to_s,
      parent_key: parent_key,
      id: nil,
      references: []
    )
  end

  def add_record_reference(entity, container, key, metadata)
    entity.references << { container: container, key: key, metadata: metadata }
    entity.id ||= positive_integer(container[key])
  end

  def registry_candidate(entity)
    exact = @registry_by_identity[[entity.kind, entity.identity_key]]
    return exact if exact

    @seed_registry_paths.each do |_path|
      candidate = @registry_by_identity[[entity.kind, entity.identity_key]]
      return candidate if candidate
    end
    nil
  end

  def registry_ids_for(kind)
    @registry_by_identity.each_with_object([]) do |((row_kind, _identity), row), ids|
      ids << row.fetch("id").to_i if row_kind == kind
    end
  end

  def write_changes!
    changed = 0
    timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    @metadata_records.sort_by(&:relative_path).each do |metadata|
      next unless metadata.changed

      FileUtils.mkdir_p(metadata.path.dirname)
      backup_metadata!(metadata) if @backup && metadata.path.file? && !metadata.created
      atomic_write(metadata.path, JSON.pretty_generate(metadata.payload) + "\n")
      changed += 1
      progress("wrote #{metadata.relative_path}") if progress_tick?(changed)
    end
    changed
  end

  def backup_metadata!(record)
    backup_root = @output_root.join("backups", Time.now.utc.strftime("%Y%m%dT%H%M%SZ"))
    destination = backup_root.join(record.relative_path)
    FileUtils.mkdir_p(destination.dirname)
    FileUtils.cp(record.path, destination)
  end

  def build_registry_content
    @registry_rows = []
    %w[work edition document].each do |kind|
      @entities.fetch(kind).values.sort_by { |entity| [entity.id, entity.identity_key] }.each do |entity|
        parent_work_id = if entity.parent_key
          @entities["work"][entity.parent_key]&.id
        end
        @registry_rows << {
          "kind" => kind,
          "id" => entity.id.to_s,
          "identity_key" => entity.identity_key,
          "path" => entity.path,
          "title" => entity.title,
          "parent_work_id" => parent_work_id.to_s,
          "source_document_id" => "",
          "status" => "active"
        }
      end
    end

    CSV.generate(encoding: "UTF-8") do |csv|
      csv << REGISTRY_HEADERS
      @registry_rows.each { |row| csv << REGISTRY_HEADERS.map { |header| row.fetch(header, "") } }
    end
  end

  def write_registry!(content)
    FileUtils.mkdir_p(@registry_path.dirname)
    if @backup && @registry_path.file?
      backup_root = @output_root.join("backups", Time.now.utc.strftime("%Y%m%dT%H%M%SZ"), "registry")
      FileUtils.mkdir_p(backup_root)
      FileUtils.cp(@registry_path, backup_root.join(@registry_path.basename))
    end
    atomic_write(@registry_path, content)
  end

  def current_registry_rows
    @registry_rows
  end

  def write_reports!(started_at)
    FileUtils.mkdir_p(@output_root)
    report = @output_root.join("metadata_id_repairs.csv")
    CSV.open(report, "w", write_headers: true,
             headers: %w[action kind old_id new_id path metadata_path], encoding: "UTF-8") do |csv|
      @changes.each { |row| csv << row }
    end
    write_scan_issue_report

    summary = {
      "started_at" => started_at.iso8601,
      "finished_at" => Time.now.utc.iso8601,
      "root" => @root.to_s,
      "registry_path" => @registry_path.to_s,
      "assigned_ids" => @assigned_ids,
      "reassigned_conflicts" => @reassigned_conflicts,
      "created_metadata_files" => @created_metadata_files,
      "added_document_records" => @added_document_records,
      "registry_rows" => current_registry_rows.length,
      "changes" => @changes.length,
      "scan_issues" => @scan_issues.length
    }
    @output_root.join("metadata_id_repair_summary.json").write(JSON.pretty_generate(summary) + "\n", encoding: "UTF-8")
    report
  end

  def write_scan_issue_report
    FileUtils.mkdir_p(@output_root)
    path = @output_root.join("metadata_id_scan_issues.csv")
    CSV.open(path, "w", write_headers: true,
             headers: %w[kind path error_class message], encoding: "UTF-8") do |csv|
      @scan_issues.each { |row| csv << row }
    end
    path
  end

  def atomic_write(path, content)
    FileUtils.mkdir_p(path.dirname)
    temporary = path.dirname.join(".#{path.basename}.metadata-id-#{Process.pid}-#{rand(1_000_000)}.tmp")
    temporary.write(content, encoding: "UTF-8")
    File.rename(temporary, path)
  ensure
    FileUtils.rm_f(temporary) if defined?(temporary) && temporary
  end

  def mark_changed(metadata)
    metadata.changed = true
  end

  def first_metadata_path(entity)
    entity.references.first&.fetch(:metadata)&.relative_path.to_s
  end

  def change_row(action, kind, old_id, new_id, entity_path, metadata_path)
    @changes << {
      "action" => action.to_s,
      "kind" => kind.to_s,
      "old_id" => old_id.to_s,
      "new_id" => new_id.to_s,
      "path" => entity_path.to_s,
      "metadata_path" => metadata_path.to_s
    }
  end

  def positive_integer(value)
    integer = Integer(value.to_s, 10)
    integer.positive? ? integer : nil
  rescue ArgumentError, TypeError
    nil
  end

  def fs_key(path)
    Pathname(path).cleanpath.to_s
  end

  def normalize_relative(value)
    text = value.to_s.tr("\\", "/").sub(%r{\A\./}, "")
    clean = Pathname(text).cleanpath.to_s.tr("\\", "/")
    raise ArgumentError, "unsafe path #{value.inspect}" if clean == ".." || clean.start_with?("../") || clean.start_with?("/")

    clean
  end

  def relative_path(path)
    normalize_relative(Pathname(path).relative_path_from(@root).to_s)
  end

  def relative_display(path)
    relative_path(path)
  rescue ArgumentError
    path.to_s
  end

  def first_present(*values)
    values.find { |value| !value.to_s.strip.empty? }.to_s
  end

  def progress_tick?(count)
    @progress_every.positive? && (count % @progress_every).zero?
  end

  def progress(message)
    if @logger
      @logger.info("[metadata_ids] #{message}")
    else
      warn "[metadata_ids] #{message}"
    end
  end
end
