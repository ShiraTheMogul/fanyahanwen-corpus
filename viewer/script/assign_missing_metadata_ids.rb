# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "find"
require "json"
require "optparse"
require "pathname"
require "set"
require "time"

class AssignMissingMetadataIds
  REGISTRY_HEADERS = %w[
    kind id identity_key path title parent_work_id source_document_id status
  ].freeze
  REUSABLE_STATUSES = [nil, "", "active", "contained"].freeze
  VALID_ALLOCATION_MODES = %w[append lowest-unused].freeze
  VALID_UNLISTED_MODES = %w[none direct all].freeze
  VALID_SOURCE_MODES = %w[clean raw all].freeze

  attr_reader :output_root

  def initialize(corpus_root:, registry_path:, output_root:, allocation: "append",
                 include_unlisted: "direct", source_mode: "clean",
                 progress_every: 25_000)
    @corpus_root = Pathname(corpus_root).expand_path
    @registry_path = Pathname(registry_path).expand_path
    @output_root = Pathname(output_root).expand_path
    @allocation = allocation.to_s
    @include_unlisted = include_unlisted.to_s
    @source_mode = source_mode.to_s
    @progress_every = progress_every.to_i

    @registry_rows = []
    @registry_by_path = Hash.new { |hash, key| hash[key] = [] }
    @registry_by_identity = Hash.new { |hash, key| hash[key] = [] }
    @registry_by_id = Hash.new { |hash, key| hash[key] = [] }
    @used_ids = Hash.new { |hash, key| hash[key] = Set.new }
    @next_ids = {}

    @metadata_paths = []
    @metadata_by_folder = {}
    @metadata_id_owners = {}
    @unseen_listed_documents = {}
    @blocked_metadata = Set.new
    @blocked_documents = Set.new
    @unlisted_by_metadata = Hash.new { |hash, key| hash[key] = [] }

    @changes = []
    @conflicts = []
    @warnings = []
    @unlisted_rows = []
    @orphan_text_rows = []
    @missing_file_rows = []
    @metadata_updates = []
    @new_registry_rows = []

    @counts = Hash.new(0)
  end

  def run
    validate_options!
    prepare_output!
    phase("Loading ID registry") { load_registry! }
    phase("Discovering metadata files") { discover_metadata! }
    phase("Auditing existing metadata IDs") { audit_existing_metadata! }
    phase("Crawling text files") { crawl_text_files! }
    phase("Assigning missing IDs") { assign_and_stage! }
    phase("Writing reports") { write_outputs! }

    ready = @conflicts.empty?
    log("Finished: ready_to_apply=#{ready} metadata_updates=#{@metadata_updates.length} " \
        "new_registry_rows=#{@new_registry_rows.length} conflicts=#{@conflicts.length}")
    ready
  end

  def self.apply_from(plan_root:, corpus_root: nil, registry_path: nil)
    PlanApplier.new(
      plan_root: plan_root,
      corpus_root: corpus_root,
      registry_path: registry_path
    ).run
  end

  private

  def validate_options!
    raise ArgumentError, "Corpus root does not exist: #{@corpus_root}" unless @corpus_root.directory?
    raise ArgumentError, "Registry does not exist: #{@registry_path}" unless @registry_path.file?
    unless VALID_ALLOCATION_MODES.include?(@allocation)
      raise ArgumentError, "Invalid allocation mode #{@allocation.inspect}; use #{VALID_ALLOCATION_MODES.join(' or ')}"
    end
    unless VALID_UNLISTED_MODES.include?(@include_unlisted)
      raise ArgumentError, "Invalid include-unlisted mode #{@include_unlisted.inspect}; use #{VALID_UNLISTED_MODES.join(', ')}"
    end
    unless VALID_SOURCE_MODES.include?(@source_mode)
      raise ArgumentError, "Invalid source mode #{@source_mode.inspect}; use #{VALID_SOURCE_MODES.join(', ')}"
    end
    if inside?(@output_root, @corpus_root)
      raise ArgumentError, "Output directory must not be inside the corpus: #{@output_root}"
    end
  end

  def prepare_output!
    if @output_root.exist? && @output_root.children.any?
      raise ArgumentError, "Output directory is not empty: #{@output_root}"
    end

    FileUtils.mkdir_p(@output_root.join("staged_metadata"))
  end

  def phase(label)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    log(label)
    yield
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    log("#{label} complete in #{format('%.1f', elapsed)}s")
  end

  def log(message)
    warn "[metadata-id] #{Time.now.utc.iso8601} #{message}"
  end

  def progress(count, label)
    return unless @progress_every.positive?
    return unless (count % @progress_every).zero?

    log("#{label}: #{count}")
  end

  def load_registry!
    table = CSV.read(@registry_path, headers: true, encoding: "bom|utf-8")
    headers = table.headers.compact
    missing_headers = REGISTRY_HEADERS - headers
    unless missing_headers.empty?
      raise ArgumentError, "Registry is missing columns: #{missing_headers.join(', ')}"
    end

    table.each_with_index do |csv_row, index|
      row = REGISTRY_HEADERS.to_h { |header| [header, csv_row[header].to_s] }
      kind = presence(row["kind"])
      id = positive_integer(row["id"])
      identity = presence(row["identity_key"])
      path = normalise_registry_path(row["path"])

      unless kind && id
        conflict("invalid_registry_row", nil, @registry_path.to_s,
                 "Row #{index + 2} has invalid kind or ID")
        next
      end

      row["kind"] = kind
      row["id"] = id.to_s
      @registry_rows << row
      @used_ids[kind] << id
      @registry_by_id[[kind, id]] << row
      @registry_by_identity[[kind, identity]] << row if identity
      @registry_by_path[[kind, path]] << row if path
      progress(@registry_rows.length, "Registry rows loaded")
    end

    validate_registry_duplicates!
  end

  def validate_registry_duplicates!
    @registry_by_id.each do |(kind, id), rows|
      identities = rows.map { |row| [presence(row["identity_key"]), normalise_registry_path(row["path"])] }.uniq
      next if identities.length <= 1

      conflict("registry_id_reused", kind, id,
               "Registry ID #{id} is attached to more than one identity/path: #{identities.inspect}")
    end

    @registry_by_path.each do |(kind, path), rows|
      ids = rows.map { |row| row.fetch("id").to_i }.uniq
      next if ids.length <= 1

      conflict("registry_path_has_multiple_ids", kind, path,
               "Registry path has IDs #{ids.sort.join(', ')}")
    end

    @registry_by_identity.each do |(kind, identity), rows|
      ids = rows.map { |row| row.fetch("id").to_i }.uniq
      next if ids.length <= 1

      conflict("registry_identity_has_multiple_ids", kind, identity,
               "Registry identity has IDs #{ids.sort.join(', ')}")
    end
  end

  def discover_metadata!
    count = 0
    Find.find(@corpus_root.to_s) do |absolute|
      path = Pathname(absolute)
      rel = relative(path)

      if path.directory?
        if excluded_directory?(rel)
          Find.prune
        else
          next
        end
      end

      next unless path.basename.to_s == "metadata.json"
      next unless selected_path?(rel)

      folder_rel = normalise_relative_path(path.dirname.relative_path_from(@corpus_root).to_s)
      metadata_rel = normalise_relative_path(path.relative_path_from(@corpus_root).to_s)
      if @metadata_by_folder.key?(folder_rel)
        conflict("duplicate_metadata_folder", "work", folder_rel,
                 "More than one metadata.json was discovered for the same folder")
        next
      end

      @metadata_paths << path
      @metadata_by_folder[folder_rel] = metadata_rel
      count += 1
      progress(count, "Metadata files discovered")
    rescue SystemCallError => error
      warning("filesystem_read_error", nil, rel, error.message)
    end

    @metadata_paths.sort_by! { |path| relative(path) }
    @counts["metadata_files"] = @metadata_paths.length
  end

  def audit_existing_metadata!
    @metadata_paths.each_with_index do |metadata_path, index|
      metadata_rel = relative(metadata_path)
      folder_rel = relative(metadata_path.dirname)
      payload = read_metadata(metadata_path, metadata_rel)
      next unless payload

      work_id_state = id_state(payload, "work_id")
      if work_id_state[:invalid]
        block_metadata(metadata_rel, "invalid_work_id", "work", folder_rel,
                       "work_id must be a positive integer or absent")
      elsif work_id_state[:id]
        validate_metadata_id!("work", work_id_state[:id], folder_rel, metadata_rel)
      else
        @counts["works_missing_id"] += 1
      end

      documents = payload["documents"]
      if documents.nil?
        progress(index + 1, "Metadata files audited")
        next
      end
      unless documents.is_a?(Array)
        block_metadata(metadata_rel, "documents_not_array", "document", metadata_rel,
                       "documents must be an array")
        progress(index + 1, "Metadata files audited")
        next
      end

      local_paths = Set.new
      documents.each_with_index do |document, document_index|
        unless document.is_a?(Hash)
          block_document(metadata_rel, "document_not_object", metadata_rel,
                         "documents[#{document_index}] is not an object")
          next
        end

        document_path = derive_document_path(document, folder_rel)
        unless document_path
          block_document(metadata_rel, "document_path_missing", metadata_rel,
                         "documents[#{document_index}] has neither a usable path nor file")
          next
        end

        if local_paths.include?(document_path)
          block_document(metadata_rel, "duplicate_document_path", document_path,
                         "The same document path appears twice in one metadata file")
          next
        end
        local_paths << document_path

        other_owner = @unseen_listed_documents[document_path]
        if other_owner && other_owner != metadata_rel
          block_document(metadata_rel, "document_claimed_by_multiple_works", document_path,
                         "Also listed by #{other_owner}")
          block_document(other_owner, "document_claimed_by_multiple_works", document_path,
                         "Also listed by #{metadata_rel}")
        else
          @unseen_listed_documents[document_path] = metadata_rel
        end

        document_id_state = id_state(document, "document_id")
        if document_id_state[:invalid]
          block_document(metadata_rel, "invalid_document_id", document_path,
                         "document_id must be a positive integer or absent")
        elsif document_id_state[:id]
          validate_metadata_id!("document", document_id_state[:id], document_path, metadata_rel)
        else
          @counts["documents_missing_id"] += 1
        end
        @counts["listed_documents"] += 1
      end

      progress(index + 1, "Metadata files audited")
    end
  end

  def validate_metadata_id!(kind, id, path, metadata_rel)
    owner_key = [kind, id]
    existing_owner = @metadata_id_owners[owner_key]
    if existing_owner && existing_owner != path
      block_metadata(metadata_rel, "metadata_id_reused", kind, id,
                     "ID #{id} is also used by #{existing_owner}")
      return
    end
    @metadata_id_owners[owner_key] = path
    @used_ids[kind] << id

    path_rows = @registry_by_path[[kind, path]]
    path_ids = path_rows.map { |row| row.fetch("id").to_i }.uniq
    if path_ids.any? && path_ids != [id]
      block_metadata(metadata_rel, "metadata_registry_path_mismatch", kind, path,
                     "metadata has ID #{id}; registry path has #{path_ids.sort.join(', ')}")
    end

    id_rows = @registry_by_id[[kind, id]]
    conflicting_rows = id_rows.reject do |row|
      row_path = normalise_registry_path(row["path"])
      row_path == path || (row_path.nil? && presence(row["identity_key"]) == canonical_identity(kind, path))
    end
    return if conflicting_rows.empty?

    details = conflicting_rows.map do |row|
      "#{row['identity_key']} (#{row['path']}, status=#{row['status']})"
    end.join("; ")
    block_metadata(metadata_rel, "metadata_id_conflicts_with_registry", kind, id,
                   "Registry already reserves this ID for #{details}")
  end

  def crawl_text_files!
    count = 0
    Find.find(@corpus_root.to_s) do |absolute|
      path = Pathname(absolute)
      rel = relative(path)

      if path.directory?
        if excluded_directory?(rel)
          Find.prune
        else
          next
        end
      end

      next unless path.extname.downcase == ".txt"
      next unless selected_path?(rel)

      count += 1
      if @unseen_listed_documents.delete(rel)
        @counts["listed_documents_found"] += 1
        progress(count, "Text files crawled")
        next
      end

      owner_metadata_rel, owner_folder_rel = nearest_metadata_owner(path.dirname)
      unless owner_metadata_rel
        @orphan_text_rows << {
          "path" => rel,
          "reason" => "no_metadata_json_in_ancestor_chain"
        }
        @counts["orphan_text_files"] += 1
        progress(count, "Text files crawled")
        next
      end

      direct = normalise_relative_path(path.dirname.relative_path_from(@corpus_root).to_s) == owner_folder_rel
      action = include_unlisted_path?(direct) ? "add_to_documents" : "report_only"
      @unlisted_rows << {
        "path" => rel,
        "owner_metadata" => owner_metadata_rel,
        "owner_folder" => owner_folder_rel,
        "direct_child" => direct.to_s,
        "action" => action
      }
      @counts["unlisted_text_files"] += 1

      if action == "add_to_documents"
        @unlisted_by_metadata[owner_metadata_rel] << rel
        @counts["unlisted_text_files_to_add"] += 1
      end
      progress(count, "Text files crawled")
    rescue SystemCallError => error
      warning("filesystem_read_error", nil, rel, error.message)
    end

    @counts["text_files"] = count
    @unseen_listed_documents.each do |document_path, metadata_rel|
      @missing_file_rows << {
        "path" => document_path,
        "metadata_path" => metadata_rel,
        "reason" => "listed_document_file_not_found"
      }
      @counts["listed_document_files_missing"] += 1
    end
  end

  def nearest_metadata_owner(directory)
    current = normalise_relative_path(directory.relative_path_from(@corpus_root).to_s)
    loop do
      metadata_rel = @metadata_by_folder[current]
      return [metadata_rel, current] if metadata_rel
      break if current == "." || current.empty?

      parent = normalise_relative_path(File.dirname(current))
      break if parent == current

      current = parent
    end
    nil
  end

  def include_unlisted_path?(direct)
    case @include_unlisted
    when "all" then true
    when "direct" then direct
    else false
    end
  end

  def assign_and_stage!
    seed_allocators!

    @metadata_paths.each_with_index do |metadata_path, index|
      metadata_rel = relative(metadata_path)
      folder_rel = relative(metadata_path.dirname)
      payload = read_metadata(metadata_path, metadata_rel)
      next unless payload
      next if @blocked_metadata.include?(metadata_rel)

      original_sha = Digest::SHA256.file(metadata_path).hexdigest
      changed = false

      work_id_state = id_state(payload, "work_id")
      work_id = work_id_state[:id]
      unless work_id
        work_id, source = resolve_or_allocate_id("work", folder_rel, metadata_rel)
        if work_id
          payload = insert_work_id(payload, work_id)
          changed = true
          change(source == "registry" ? "reuse_registry_id" : "assign_new_id",
                 "work", work_id, folder_rel, metadata_rel,
                 source == "registry" ? "reused stable ID from registry" : allocation_detail)
        end
      end
      next unless work_id

      unless ensure_registry_entry!(
        kind: "work",
        id: work_id,
        path: folder_rel,
        title: presence(payload["title"]) || File.basename(folder_rel),
        parent_work_id: nil,
        status: Array(payload["contained_in"]).empty? ? "active" : "contained",
        metadata_rel: metadata_rel
      )
        next
      end

      documents = payload["documents"]
      documents = [] if documents.nil?
      unless documents.is_a?(Array)
        next
      end

      known_paths = Set.new
      documents.each do |document|
        next unless document.is_a?(Hash)

        document_path = derive_document_path(document, folder_rel)
        next unless document_path

        known_paths << document_path
        if presence(document["path"]) != document_path
          document["path"] = document_path
          changed = true
          change("normalise_document_path", "document", document["document_id"], document_path,
                 metadata_rel, "stored a corpus-root-relative path")
        end
        if presence(document["file"]).nil?
          document["file"] = File.basename(document_path)
          changed = true
          change("add_document_file_name", "document", document["document_id"], document_path,
                 metadata_rel, "derived file from path")
        end
      end

      Array(@unlisted_by_metadata[metadata_rel]).sort.each do |document_path|
        next if known_paths.include?(document_path)

        documents << {
          "file" => File.basename(document_path),
          "path" => document_path
        }
        known_paths << document_path
        changed = true
        change("add_unlisted_document", "document", nil, document_path, metadata_rel,
               "added an existing text file to documents")
      end
      payload["documents"] = documents unless documents.empty? && payload["documents"].nil?

      documents.sort_by { |document| derive_document_path(document, folder_rel).to_s }.each do |document|
        next unless document.is_a?(Hash)

        document_path = derive_document_path(document, folder_rel)
        next unless document_path
        next if @blocked_documents.include?([metadata_rel, document_path])

        file_exists = @corpus_root.join(document_path).file?
        document_id_state = id_state(document, "document_id")
        document_id = document_id_state[:id]
        unless document_id
          unless file_exists
            warning("missing_file_not_assigned", "document", document_path,
                    "No document_id was assigned because the listed file does not exist")
            next
          end

          document_id, source = resolve_or_allocate_id("document", document_path, metadata_rel)
          next unless document_id

          replace_hash_contents!(document, insert_document_id(document, document_id))
          changed = true
          change(source == "registry" ? "reuse_registry_id" : "assign_new_id",
                 "document", document_id, document_path, metadata_rel,
                 source == "registry" ? "reused stable ID from registry" : allocation_detail)
        end

        ensure_registry_entry!(
          kind: "document",
          id: document_id,
          path: document_path,
          title: presence(document["title"]) || File.basename(document_path, ".txt"),
          parent_work_id: work_id,
          status: "active",
          metadata_rel: metadata_rel
        )
      end

      if changed
        stage_metadata!(metadata_path, metadata_rel, payload, original_sha)
      end
      progress(index + 1, "Metadata files assigned")
    end
  end

  def resolve_or_allocate_id(kind, path, metadata_rel)
    rows = reusable_registry_rows(kind, path, metadata_rel)
    return nil unless rows

    ids = rows.map { |row| row.fetch("id").to_i }.uniq
    if ids.length > 1
      block_metadata(metadata_rel, "ambiguous_registry_match", kind, path,
                     "Registry provides more than one reusable ID: #{ids.sort.join(', ')}")
      return nil
    end

    if ids.length == 1
      id = ids.first
      owner = @metadata_id_owners[[kind, id]]
      if owner && owner != path
        block_metadata(metadata_rel, "registry_id_owned_by_other_metadata", kind, id,
                       "Registry ID is already used by #{owner}")
        return nil
      end
      @metadata_id_owners[[kind, id]] = path
      @used_ids[kind] << id
      return [id, "registry"]
    end

    id = next_id(kind)
    @metadata_id_owners[[kind, id]] = path
    [id, "allocated"]
  end

  def reusable_registry_rows(kind, path, metadata_rel)
    rows = @registry_by_path[[kind, path]]
    rows = @registry_by_identity[[kind, canonical_identity(kind, path)]] if rows.empty?

    retired = rows.reject { |row| REUSABLE_STATUSES.include?(presence(row["status"])) }
    unless retired.empty?
      statuses = retired.map { |row| presence(row["status"]) }.uniq
      block_metadata(metadata_rel, "retired_registry_identity_reappeared", kind, path,
                     "Registry path/identity is marked #{statuses.join(', ')} and will not be reused")
      return nil
    end
    rows
  end

  def seed_allocators!
    %w[work document].each do |kind|
      @next_ids[kind] = if @allocation == "append"
        @used_ids[kind].max.to_i + 1
      else
        1
      end
    end
  end

  def next_id(kind)
    candidate = @next_ids.fetch(kind)
    candidate += 1 while @used_ids[kind].include?(candidate)
    @used_ids[kind] << candidate
    @next_ids[kind] = candidate + 1
    candidate
  end

  def ensure_registry_entry!(kind:, id:, path:, title:, parent_work_id:, status:, metadata_rel:)
    exact = @registry_by_path[[kind, path]].find { |row| row.fetch("id").to_i == id }
    return true if exact

    identity = canonical_identity(kind, path)
    identity_row = @registry_by_identity[[kind, identity]].find { |row| row.fetch("id").to_i == id }
    if identity_row
      old_path = presence(identity_row["path"])
      if old_path && normalise_registry_path(old_path) != path
        block_metadata(metadata_rel, "registry_identity_path_mismatch", kind, path,
                       "Identity #{identity} already points to #{old_path}")
        return false
      end
      identity_row["path"] = path
      identity_row["title"] = title.to_s if presence(identity_row["title"]).nil?
      identity_row["parent_work_id"] = parent_work_id.to_s if parent_work_id && presence(identity_row["parent_work_id"]).nil?
      identity_row["status"] = status if presence(identity_row["status"]).nil?
      @registry_by_path[[kind, path]] << identity_row
      change("repair_registry_row", kind, id, path, metadata_rel,
             "filled missing path or descriptive fields in an existing registry row")
      return true
    end

    other_id_rows = @registry_by_id[[kind, id]]
    unless other_id_rows.empty?
      details = other_id_rows.map { |row| "#{row['identity_key']} (#{row['path']})" }.join("; ")
      block_metadata(metadata_rel, "cannot_register_existing_id", kind, id,
                     "ID is already reserved by #{details}")
      return false
    end

    row = {
      "kind" => kind,
      "id" => id.to_s,
      "identity_key" => identity,
      "path" => path,
      "title" => title.to_s,
      "parent_work_id" => parent_work_id.to_s,
      "source_document_id" => "",
      "status" => status
    }
    @registry_rows << row
    @new_registry_rows << row
    @registry_by_id[[kind, id]] << row
    @registry_by_identity[[kind, identity]] << row
    @registry_by_path[[kind, path]] << row
    @used_ids[kind] << id
    change("add_registry_row", kind, id, path, metadata_rel,
           "registered an ID present in or newly assigned to metadata")
    true
  end

  def stage_metadata!(source_path, metadata_rel, payload, original_sha)
    staged_path = @output_root.join("staged_metadata", metadata_rel)
    FileUtils.mkdir_p(staged_path.dirname)
    text = JSON.pretty_generate(payload) + "\n"
    staged_path.write(text, encoding: "UTF-8")
    @metadata_updates << {
      "relative_path" => metadata_rel,
      "original_sha256" => original_sha,
      "staged_path" => staged_path.relative_path_from(@output_root).to_s.tr("\\", "/"),
      "staged_sha256" => Digest::SHA256.file(staged_path).hexdigest
    }
    @counts["metadata_files_changed"] += 1
  end

  def write_outputs!
    write_csv("changes.csv", %w[action kind id path metadata_path detail], @changes)
    write_csv("conflicts.csv", %w[code kind path detail], @conflicts)
    write_csv("warnings.csv", %w[code kind path detail], @warnings)
    write_csv("unlisted_text_files.csv", %w[path owner_metadata owner_folder direct_child action], @unlisted_rows)
    write_csv("orphan_text_files.csv", %w[path reason], @orphan_text_rows)
    write_csv("listed_document_files_missing.csv", %w[path metadata_path reason], @missing_file_rows)
    write_csv("new_registry_rows.csv", REGISTRY_HEADERS, @new_registry_rows)

    updated_registry_path = @output_root.join("metadata_id_registry.updated.csv")
    CSV.open(updated_registry_path, "wb", encoding: "UTF-8") do |csv|
      csv << REGISTRY_HEADERS
      @registry_rows.each { |row| csv << REGISTRY_HEADERS.map { |header| row[header].to_s } }
    end

    summary = {
      "ready_to_apply" => @conflicts.empty?,
      "allocation" => @allocation,
      "include_unlisted" => @include_unlisted,
      "source_mode" => @source_mode,
      "corpus_root" => @corpus_root.to_s,
      "registry_path" => @registry_path.to_s,
      "registry_original_sha256" => Digest::SHA256.file(@registry_path).hexdigest,
      "registry_updated_sha256" => Digest::SHA256.file(updated_registry_path).hexdigest,
      "counts" => @counts.sort.to_h,
      "conflict_count" => @conflicts.length,
      "warning_count" => @warnings.length,
      "metadata_updates" => @metadata_updates
    }
    @output_root.join("plan.json").write(JSON.pretty_generate(summary) + "\n", encoding: "UTF-8")
    @output_root.join("summary.json").write(JSON.pretty_generate(summary.except("metadata_updates")) + "\n", encoding: "UTF-8")
    @output_root.join("ASSIGNMENT_REPORT.md").write(build_report(summary), encoding: "UTF-8")
  end

  def build_report(summary)
    counts = summary.fetch("counts")
    <<~MARKDOWN
      # Missing metadata ID assignment report

      Ready to apply: **#{summary.fetch('ready_to_apply')}**

      ## Rules used

      - Registry: `#{summary.fetch('registry_path')}`
      - Corpus: `#{summary.fetch('corpus_root')}`
      - Allocation: `#{summary.fetch('allocation')}`
      - Unlisted text handling: `#{summary.fetch('include_unlisted')}`
      - Source mode: `#{summary.fetch('source_mode')}`

      `append` is the safe allocation mode. It assigns IDs above the greatest ID ever
      recorded for that kind. Gaps are deliberately left alone because an old URL or
      external citation may still refer to a retired ID.

      `lowest-unused` only chooses numbers absent from both the supplied registry and
      all existing metadata. Use it only when the supplied registry is known to be the
      complete historical ledger.

      ## Counts

      #{counts.map { |key, value| "- #{key}: #{value}" }.join("\n")}

      - conflicts: #{@conflicts.length}
      - warnings: #{@warnings.length}
      - new registry rows: #{@new_registry_rows.length}
      - staged metadata files: #{@metadata_updates.length}

      ## Apply

      Review `conflicts.csv`, `changes.csv`, `unlisted_text_files.csv`, and the staged
      metadata first. When `ready_to_apply` is true, run:

      ```bash
      ruby script/assign_missing_metadata_ids.rb --apply-from #{shell_quote(@output_root.to_s)}
      ```

      Apply mode checks SHA-256 hashes before writing. It refuses to continue if the
      registry or any affected metadata file changed after this dry run.
    MARKDOWN
  end

  def read_metadata(path, metadata_rel)
    raw = path.read(encoding: "bom|utf-8")
    payload = JSON.parse(raw)
    unless payload.is_a?(Hash)
      block_metadata(metadata_rel, "metadata_not_object", "work", metadata_rel,
                     "Top-level JSON must be an object")
      return nil
    end
    payload
  rescue JSON::ParserError => error
    block_metadata(metadata_rel, "invalid_json", "work", metadata_rel, error.message)
    nil
  rescue SystemCallError => error
    block_metadata(metadata_rel, "metadata_read_error", "work", metadata_rel, error.message)
    nil
  end

  def derive_document_path(document, folder_rel)
    raw_path = presence(document["path"])
    raw_file = presence(document["file"])
    candidate = if raw_path
      normalise_relative_path(raw_path)
    elsif raw_file
      normalise_relative_path(File.join(folder_rel, raw_file))
    end
    return nil unless candidate
    return nil if unsafe_relative_path?(candidate)

    if !candidate.include?("/") && folder_rel != "."
      candidate = normalise_relative_path(File.join(folder_rel, candidate))
    end
    candidate
  end

  def unsafe_relative_path?(path)
    value = path.to_s
    return true if value.empty?
    return true if value.start_with?("/")
    return true if value.match?(/\A[A-Za-z]:\//)

    clean = Pathname(value).cleanpath.to_s.tr("\\", "/")
    clean == ".." || clean.start_with?("../")
  end

  def insert_work_id(payload, id)
    source = payload.reject { |key, _value| key == "work_id" }
    result = {}
    inserted = false
    source.each do |key, value|
      result[key] = value
      next unless key == "schema_version"

      result["work_id"] = id
      inserted = true
    end
    result = { "work_id" => id }.merge(result) unless inserted
    result
  end

  def insert_document_id(document, id)
    { "document_id" => id }.merge(document.reject { |key, _value| key == "document_id" })
  end

  def replace_hash_contents!(target, replacement)
    target.clear
    replacement.each { |key, value| target[key] = value }
  end

  def id_state(hash, key)
    value = hash[key]
    return { id: nil, invalid: false } if value.nil? || value.to_s.strip.empty?

    id = positive_integer(value)
    { id: id, invalid: id.nil? }
  end

  def positive_integer(value)
    integer = Integer(value.to_s, 10)
    integer.positive? ? integer : nil
  rescue ArgumentError, TypeError
    nil
  end

  def normalise_registry_path(path)
    value = presence(path)
    return nil unless value

    normalise_relative_path(value)
  end

  def normalise_relative_path(path)
    value = path.to_s.dup
    value.force_encoding(Encoding::UTF_8) if value.encoding == Encoding::ASCII_8BIT
    raise ArgumentError, "Path is not valid UTF-8: #{path.inspect}" unless value.valid_encoding?

    value = value.tr("\\", "/").sub(%r{\A\./}, "")
    value = "." if value.empty?
    cleaned = Pathname(value).cleanpath.to_s.tr("\\", "/")
    cleaned.force_encoding(Encoding::UTF_8)
  end

  def canonical_identity(kind, path)
    "#{kind}:#{path}"
  end

  def relative(path)
    normalise_relative_path(Pathname(path).relative_path_from(@corpus_root).to_s)
  end

  def selected_path?(rel)
    components = rel.split("/")
    case @source_mode
    when "clean" then !components.include?("raw")
    when "raw" then components.include?("raw")
    else true
    end
  end

  def excluded_directory?(rel)
    components = rel.split("/")
    return true if components.include?(".git") || components.include?(".svn") || components.include?("node_modules")
    return true if @source_mode == "clean" && components.include?("raw")
    return true if @source_mode == "raw" && components.include?("clean")

    false
  end

  def inside?(child, parent)
    child_string = child.cleanpath.to_s
    parent_string = parent.cleanpath.to_s
    child_string == parent_string || child_string.start_with?(parent_string + File::SEPARATOR)
  end

  def block_metadata(metadata_rel, code, kind, path, detail)
    @blocked_metadata << metadata_rel
    conflict(code, kind, path, detail)
  end

  def block_document(metadata_rel, code, path, detail)
    @blocked_documents << [metadata_rel, path]
    conflict(code, "document", path, detail)
  end

  def conflict(code, kind, path, detail)
    @conflicts << {
      "code" => code.to_s,
      "kind" => kind.to_s,
      "path" => path.to_s,
      "detail" => detail.to_s
    }
  end

  def warning(code, kind, path, detail)
    @warnings << {
      "code" => code.to_s,
      "kind" => kind.to_s,
      "path" => path.to_s,
      "detail" => detail.to_s
    }
  end

  def change(action, kind, id, path, metadata_path, detail)
    @changes << {
      "action" => action.to_s,
      "kind" => kind.to_s,
      "id" => id.to_s,
      "path" => path.to_s,
      "metadata_path" => metadata_path.to_s,
      "detail" => detail.to_s
    }
  end

  def allocation_detail
    @allocation == "append" ? "allocated above the recorded maximum" : "allocated the lowest number absent from the complete registry"
  end

  def write_csv(name, headers, rows)
    CSV.open(@output_root.join(name), "wb", encoding: "UTF-8") do |csv|
      csv << headers
      rows.each { |row| csv << headers.map { |header| row[header].to_s } }
    end
  end

  def presence(value)
    text = value.to_s.strip
    text.empty? ? nil : text
  end

  def shell_quote(value)
    "'#{value.to_s.gsub("'", %q('"'"'))}'"
  end

  class PlanApplier
    def initialize(plan_root:, corpus_root: nil, registry_path: nil)
      @plan_root = Pathname(plan_root).expand_path
      @plan_path = @plan_root.join("plan.json")
      raise ArgumentError, "Plan does not exist: #{@plan_path}" unless @plan_path.file?

      @plan = JSON.parse(@plan_path.read(encoding: "UTF-8"))
      @corpus_root = Pathname(corpus_root || @plan.fetch("corpus_root")).expand_path
      @registry_path = Pathname(registry_path || @plan.fetch("registry_path")).expand_path
      @updated_registry = @plan_root.join("metadata_id_registry.updated.csv")
    end

    def run
      raise "Plan is blocked; review conflicts.csv" unless @plan["ready_to_apply"]
      raise "Corpus root does not exist: #{@corpus_root}" unless @corpus_root.directory?
      raise "Registry does not exist: #{@registry_path}" unless @registry_path.file?
      raise "Updated registry is missing: #{@updated_registry}" unless @updated_registry.file?
      raise "Plan was already applied" if @plan_root.join("APPLIED.json").exist?

      verify_inputs!
      backup_root = @plan_root.join("backup_on_apply", Time.now.utc.strftime("%Y%m%dT%H%M%SZ"))
      FileUtils.mkdir_p(backup_root)
      backed_up = []

      begin
        backup_file(@registry_path, backup_root.join("registry", @registry_path.basename), backed_up)
        Array(@plan["metadata_updates"]).each do |entry|
          destination = safe_corpus_path(entry.fetch("relative_path"))
          backup_file(destination, backup_root.join("metadata", entry.fetch("relative_path")), backed_up)
        end

        Array(@plan["metadata_updates"]).each do |entry|
          destination = safe_corpus_path(entry.fetch("relative_path"))
          staged = @plan_root.join(entry.fetch("staged_path"))
          atomic_copy(staged, destination)
        end
        atomic_copy(@updated_registry, @registry_path)
        verify_installed!

        applied = {
          "applied_at" => Time.now.utc.iso8601,
          "corpus_root" => @corpus_root.to_s,
          "registry_path" => @registry_path.to_s,
          "metadata_files_written" => Array(@plan["metadata_updates"]).length,
          "backup_root" => backup_root.to_s
        }
        @plan_root.join("APPLIED.json").write(JSON.pretty_generate(applied) + "\n", encoding: "UTF-8")
        warn "[metadata-id] Applied #{applied['metadata_files_written']} metadata files and the registry."
        true
      rescue StandardError
        backed_up.reverse_each do |source, backup|
          FileUtils.mkdir_p(source.dirname)
          FileUtils.cp(backup, source)
        end
        warn "[metadata-id] Apply failed; restored files from #{backup_root}"
        raise
      end
    end

    private

    def verify_inputs!
      expected_registry = @plan.fetch("registry_original_sha256")
      actual_registry = Digest::SHA256.file(@registry_path).hexdigest
      unless actual_registry == expected_registry
        raise "Registry changed after dry run: expected #{expected_registry}, got #{actual_registry}"
      end

      expected_updated = @plan.fetch("registry_updated_sha256")
      actual_updated = Digest::SHA256.file(@updated_registry).hexdigest
      unless actual_updated == expected_updated
        raise "Staged registry was modified: expected #{expected_updated}, got #{actual_updated}"
      end

      Array(@plan["metadata_updates"]).each do |entry|
        source = safe_corpus_path(entry.fetch("relative_path"))
        staged = @plan_root.join(entry.fetch("staged_path")).cleanpath
        ensure_inside!(staged, @plan_root)
        raise "Current metadata file is missing: #{source}" unless source.file?
        raise "Staged metadata file is missing: #{staged}" unless staged.file?

        actual_source = Digest::SHA256.file(source).hexdigest
        unless actual_source == entry.fetch("original_sha256")
          raise "Metadata changed after dry run: #{entry.fetch('relative_path')}"
        end
        actual_staged = Digest::SHA256.file(staged).hexdigest
        unless actual_staged == entry.fetch("staged_sha256")
          raise "Staged metadata was modified: #{entry.fetch('relative_path')}"
        end
        JSON.parse(staged.read(encoding: "UTF-8"))
      end
    end

    def verify_installed!
      actual_registry = Digest::SHA256.file(@registry_path).hexdigest
      unless actual_registry == @plan.fetch("registry_updated_sha256")
        raise "Installed registry does not match the reviewed staged registry"
      end

      Array(@plan["metadata_updates"]).each do |entry|
        destination = safe_corpus_path(entry.fetch("relative_path"))
        actual = Digest::SHA256.file(destination).hexdigest
        unless actual == entry.fetch("staged_sha256")
          raise "Installed metadata does not match staged metadata: #{entry.fetch('relative_path')}"
        end
      end
    end

    def backup_file(source, backup, backed_up)
      FileUtils.mkdir_p(backup.dirname)
      FileUtils.cp(source, backup)
      backed_up << [source, backup]
    end

    def atomic_copy(source, destination)
      FileUtils.mkdir_p(destination.dirname)
      temporary = destination.dirname.join(".#{destination.basename}.metadata-id-#{Process.pid}.tmp")
      FileUtils.cp(source, temporary)
      File.chmod(destination.stat.mode & 0o7777, temporary) if destination.exist?
      File.rename(temporary, destination)
    ensure
      FileUtils.rm_f(temporary) if defined?(temporary) && temporary
    end

    def safe_corpus_path(relative_path)
      path = @corpus_root.join(relative_path).cleanpath
      ensure_inside!(path, @corpus_root)
      path
    end

    def ensure_inside!(path, root)
      path_string = path.to_s
      root_string = root.cleanpath.to_s
      return if path_string == root_string || path_string.start_with?(root_string + File::SEPARATOR)

      raise "Unsafe path outside root: #{path}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  options = {
    allocation: "append",
    include_unlisted: "direct",
    source_mode: "clean",
    progress_every: 25_000
  }

  parser = OptionParser.new do |opts|
    opts.banner = <<~BANNER
      Usage:
        ruby script/assign_missing_metadata_ids.rb --corpus-root DIR --registry CSV --output DIR [options]
        ruby script/assign_missing_metadata_ids.rb --apply-from DIR [--corpus-root DIR] [--registry CSV]
    BANNER
    opts.on("--corpus-root DIR", "Corpus root") { |value| options[:corpus_root] = value }
    opts.on("--registry CSV", "Canonical metadata_id_registry.csv") { |value| options[:registry_path] = value }
    opts.on("--output DIR", "New, empty dry-run output directory") { |value| options[:output_root] = value }
    opts.on("--allocation MODE", AssignMissingMetadataIds::VALID_ALLOCATION_MODES.join(" or ")) { |value| options[:allocation] = value }
    opts.on("--include-unlisted MODE", "none, direct, or all; default direct") { |value| options[:include_unlisted] = value }
    opts.on("--source-mode MODE", "clean, raw, or all; default clean") { |value| options[:source_mode] = value }
    opts.on("--progress-every N", Integer, "Progress interval; 0 disables") { |value| options[:progress_every] = value }
    opts.on("--apply-from DIR", "Apply a previously reviewed dry-run plan") { |value| options[:apply_from] = value }
  end

  parser.parse!(ARGV)

  if options[:apply_from]
    AssignMissingMetadataIds.apply_from(
      plan_root: options.fetch(:apply_from),
      corpus_root: options[:corpus_root],
      registry_path: options[:registry_path]
    )
  else
    missing = %i[corpus_root registry_path output_root].select { |key| options[key].to_s.empty? }
    unless missing.empty?
      warn parser
      abort "Missing required option(s): #{missing.join(', ')}"
    end

    ready = AssignMissingMetadataIds.new(
      corpus_root: options.fetch(:corpus_root),
      registry_path: options.fetch(:registry_path),
      output_root: options.fetch(:output_root),
      allocation: options.fetch(:allocation),
      include_unlisted: options.fetch(:include_unlisted),
      source_mode: options.fetch(:source_mode),
      progress_every: options.fetch(:progress_every)
    ).run
    exit(ready ? 0 : 2)
  end
end
