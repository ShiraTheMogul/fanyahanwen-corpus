#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "digest"
require "fileutils"
require "json"
require "optparse"
require "pathname"
require "set"
require "time"
require "unicode_normalize/normalize"
require "zlib"
require "zip"

# Converts two flat Singapore collection folders into the JSON-era corpus shape:
#
#   collection/
#     metadata.json                  # compilation metadata
#     Short physical title__w123/
#       metadata.json                # full scholarly title and stable IDs
#       text.txt                     # body only
#
# The source is read directly from a ZIP archive. This is deliberate: several
# legacy filenames exceed WSL's byte-based NAME_MAX even though Windows/NTFS can
# store them. Archive-to-archive migration avoids extracting those names first.
class SingaporeFlatCollectionFolderiser
  TARGETS = ["名勝古跡", "新洲雅苑懷舊集"].freeze
  ARCHIVE_ROOT = "新加坡漢文"
  CLEAN_ROOT = "#{ARCHIVE_ROOT}/clean"
  SCHEMA_VERSION = 1
  PLAN_VERSION = 1
  DEFAULT_TITLE_CHARS = 36
  DEFAULT_READ_RETRIES = 5
  HEADER_PATTERN = /\A#\s*([^:：]+?)\s*[:：]\s*(.*?)\s*\z/.freeze
  LEGACY_METADATA_LINE = /\A#\s*[A-Z][A-Z0-9_ ]{1,80}\s*[:：]/.freeze
  UNSAFE_COMPONENT_CHARS = /[<>:"\/\\|?*\u0000-\u001F]/.freeze
  RESERVED_WINDOWS_NAMES = /\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?\z/i.freeze

  LegacyText = Struct.new(
    :title,
    :authors,
    :sources,
    :nation,
    :body,
    :body_sha256,
    :header_lines,
    :encoding_repairs,
    keyword_init: true
  )

  def initialize(options)
    @source_zip = Pathname(options.fetch(:source_zip)).expand_path
    @corpus_root = options[:corpus_root] && Pathname(options[:corpus_root]).expand_path
    @output_root = Pathname(options.fetch(:output_root)).expand_path
    @output_zip = Pathname(options.fetch(:output_zip)).expand_path
    @apply = options.fetch(:apply)
    @replan = options.fetch(:replan)
    @extract_tree = options.fetch(:extract_tree)
    @accept_utf8_repairs = options.fetch(:accept_utf8_repairs, false)
    @max_title_chars = Integer(options.fetch(:max_title_chars))
    @work_id_start_override = options[:work_id_start] && Integer(options[:work_id_start])
    @document_id_start_override = options[:document_id_start] && Integer(options[:document_id_start])
    @id_registry_path = options[:id_registry] && Pathname(options[:id_registry]).expand_path
    @read_retries = Integer(options.fetch(:read_retries))
    @progress_every = Integer(options.fetch(:progress_every))
    @targets = Array(options.fetch(:targets)).map(&:to_s).uniq
    @started_at = Time.now.utc
    @scan_errors = []
    @validation_errors = []
  end

  def run
    validate_options!
    FileUtils.mkdir_p(@output_root)

    plan = if @apply && plan_path.file? && !@replan
      progress "loading reviewed plan #{plan_path}"
      load_plan
    else
      progress "building folderisation plan"
      built = build_plan
      write_plan_reports(built)
      built
    end

    print_summary(plan)
    return unless @apply

    validate_plan_before_apply!(plan)
    progress "writing repaired archive #{@output_zip}"
    write_output_zip(plan)
    verify_output_zip!(plan)
    write_repaired_tree(plan) if @extract_tree
    write_install_notes(plan)
    progress "finished"
  end

  private

  def validate_options!
    raise ArgumentError, "Source ZIP does not exist: #{@source_zip}" unless @source_zip.file?

    # Check the archive before reading the large ID registry. This makes malformed
    # or unexpectedly-shaped ZIPs fail in seconds rather than after unrelated work.
    Zip::File.open(@source_zip.to_s) { |zip| validate_archive_shape!(zip) }

    raise ArgumentError, "--max-title-chars must be at least 12" if @max_title_chars < 12
    raise ArgumentError, "No target folders were supplied" if @targets.empty?

    unless @work_id_start_override && @document_id_start_override
      @id_registry_path ||= discover_id_registry
      unless @id_registry_path&.file?
        raise ArgumentError, <<~MESSAGE.strip
          No authoritative metadata ID registry was found. Pass --id-registry PATH,
          or pass both --work-id-start and --document-id-start after independently
          verifying those values. The script deliberately does not crawl the live
          corpus merely to discover maximum IDs.
        MESSAGE
      end
    end

    if @output_zip == @source_zip
      raise ArgumentError, "Output ZIP must not overwrite the source ZIP"
    end
  end

  def build_plan
    source_digest = sha256_file(@source_zip)
    inventory = build_id_inventory
    next_work_id = @work_id_start_override || inventory.fetch(:max_work_id) + 1
    next_document_id = @document_id_start_override || inventory.fetch(:max_document_id) + 1

    if inventory.fetch(:work_ids).include?(next_work_id)
      raise ArgumentError, "Requested first work_id #{next_work_id} is already in use"
    end
    if inventory.fetch(:document_ids).include?(next_document_id)
      raise ArgumentError, "Requested first document_id #{next_document_id} is already in use"
    end

    collections = []
    all_rows = []

    Zip::File.open(@source_zip.to_s) do |zip|
      validate_archive_shape!(zip)

      @targets.sort.each do |target|
        parent_entry = "#{CLEAN_ROOT}/#{target}/metadata.json"
        if find_entry_by_normalized_name(zip, parent_entry)
          @validation_errors << error_row(target, parent_entry, "parent_metadata_exists", "Target already has metadata.json")
          next
        end

        source_entries = flat_txt_entries(zip, target)
        if source_entries.empty?
          @validation_errors << error_row(target, "#{CLEAN_ROOT}/#{target}", "no_flat_txt_files", "No immediate TXT files found")
          next
        end

        parent_work_id = next_work_id
        next_work_id += 1
        edition_label = "#{target}本"
        works = []

        source_entries.sort_by { |entry| normalize_zip_name(entry.name).unicode_normalize(:nfc) }.each_with_index do |entry, index|
          source_name = normalize_zip_name(entry.name)
          parsed = parse_legacy_text(entry.get_input_stream.read, source_name)
          work_id = next_work_id
          document_id = next_document_id
          next_work_id += 1
          next_document_id += 1
          edition_id = index + 1
          physical_folder = short_physical_folder(parsed.title, work_id)
          target_folder = "#{CLEAN_ROOT}/#{target}/#{physical_folder}"
          target_text = "#{target_folder}/text.txt"
          target_metadata = "#{target_folder}/metadata.json"

          work = {
            "source_entry" => source_name,
            "source_basename" => File.basename(source_name),
            "source_sha256" => Digest::SHA256.hexdigest(entry.get_input_stream.read),
            "body_sha256" => parsed.body_sha256,
            "title" => parsed.title,
            "authors" => parsed.authors,
            "sources" => parsed.sources,
            "nation" => parsed.nation,
            "header_lines" => parsed.header_lines,
            "encoding_repairs" => parsed.encoding_repairs,
            "encoding_repair_count" => parsed.encoding_repairs.length,
            "work_id" => work_id,
            "document_id" => document_id,
            "edition_id" => edition_id,
            "edition_label" => edition_label,
            "physical_folder" => physical_folder,
            "target_folder" => target_folder,
            "target_text" => target_text,
            "target_metadata" => target_metadata,
            "title_characters" => parsed.title.each_grapheme_cluster.count,
            "physical_folder_bytes" => physical_folder.bytesize
          }
          works << work
          all_rows << work.merge("collection" => target, "parent_work_id" => parent_work_id)
        rescue StandardError => error
          @validation_errors << error_row(target, normalize_zip_name(entry.name), error.class.name, error.message)
        end

        collections << {
          "title" => target,
          "parent_work_id" => parent_work_id,
          "edition_label" => edition_label,
          "source_folder" => "#{CLEAN_ROOT}/#{target}",
          "metadata_path" => parent_entry,
          "works" => works
        }
      end
    end

    if @validation_errors.any?
      write_validation_errors
      raise ArgumentError, "Plan has #{@validation_errors.length} validation error(s); review #{validation_errors_path}"
    end

    {
      "plan_version" => PLAN_VERSION,
      "created_at" => Time.now.utc.iso8601,
      "source_zip" => @source_zip.to_s,
      "source_zip_sha256" => source_digest,
      "corpus_root" => @corpus_root&.to_s,
      "archive_root" => ARCHIVE_ROOT,
      "targets" => @targets.sort,
      "max_title_characters" => @max_title_chars,
      "id_inventory" => {
        "existing_work_ids" => inventory.fetch(:work_ids).length,
        "existing_document_ids" => inventory.fetch(:document_ids).length,
        "maximum_work_id" => inventory.fetch(:max_work_id),
        "maximum_document_id" => inventory.fetch(:max_document_id),
        "source" => inventory.fetch(:source),
        "source_sha256" => inventory.fetch(:source_digest),
        "first_new_work_id" => collections.map { |c| c["parent_work_id"] }.min,
        "last_new_work_id" => all_rows.map { |r| r["work_id"] }.max,
        "first_new_document_id" => all_rows.map { |r| r["document_id"] }.min,
        "last_new_document_id" => all_rows.map { |r| r["document_id"] }.max
      },
      "summary" => {
        "collections" => collections.length,
        "contained_works" => all_rows.length,
        "documents" => all_rows.length,
        "legacy_headers_removed" => all_rows.sum { |row| row["header_lines"].to_i },
        "documents_with_utf8_repairs" => all_rows.count { |row| row["encoding_repair_count"].to_i.positive? },
        "invalid_utf8_sequences_removed" => all_rows.sum { |row| row["encoding_repair_count"].to_i }
      },
      "collections" => collections
    }
  end

  def build_id_inventory
    work_ids = Set.new
    document_ids = Set.new
    source = nil
    source_digest = nil

    if @work_id_start_override && @document_id_start_override
      source = "explicit CLI starts"
    else
      source = @id_registry_path.to_s
      source_digest = sha256_file(@id_registry_path)
      progress "reading authoritative metadata ID registry #{@id_registry_path}"

      rows = 0
      CSV.foreach(@id_registry_path, headers: true, encoding: "bom|utf-8") do |row|
        kind = row["kind"].to_s
        id = integer_id(row["id"])
        next unless id

        case kind
        when "work"
          work_ids << id
        when "document"
          document_ids << id
        end
        rows += 1
        maybe_progress(rows, "ID-registry rows checked")
      end
    end

    # The source ZIP may already contain records created after the registry
    # snapshot. Include those IDs without traversing the live corpus.
    Zip::File.open(@source_zip.to_s) do |zip|
      zip.each do |entry|
        raw_entry_name = entry.name.to_s
        entry_name = normalize_zip_name(raw_entry_name)
        next unless entry_name.end_with?("metadata.json")

        text = entry.get_input_stream.read.force_encoding(Encoding::UTF_8)
        raise Encoding::InvalidByteSequenceError, "invalid UTF-8 in #{entry_name}" unless text.valid_encoding?
        collect_ids(JSON.parse(text), work_ids, document_ids)
      rescue JSON::ParserError, Encoding::InvalidByteSequenceError => error
        @scan_errors << {
          "path" => entry_name || raw_entry_name.inspect,
          "operation" => "zip_metadata_read",
          "error_class" => error.class.name,
          "message" => error.message
        }
      end
    end

    if @scan_errors.any?
      write_scan_errors
      raise ArgumentError, "Source archive metadata could not be read completely; review #{scan_errors_path}"
    end

    {
      work_ids: work_ids,
      document_ids: document_ids,
      max_work_id: work_ids.max.to_i,
      max_document_id: document_ids.max.to_i,
      source: source,
      source_digest: source_digest
    }
  end

  def discover_id_registry
    roots = []
    roots.concat(Dir.glob(File.expand_path("tmp/corpus_metadata_json/full_*/metadata_id_registry.csv", Dir.pwd)))
    roots.concat(Dir.glob(File.expand_path("tmp/**/metadata_id_registry.csv", Dir.pwd)))
    candidates = roots.uniq.map { |path| Pathname(path) }.select(&:file?)
    candidates.max_by { |path| [path.mtime.to_i, path.to_s] }
  end

  def collect_ids(object, work_ids, document_ids)
    case object
    when Hash
      object.each do |key, value|
        if key.to_s == "work_id"
          id = integer_id(value)
          work_ids << id if id
        elsif key.to_s == "document_id"
          id = integer_id(value)
          document_ids << id if id
        end
        collect_ids(value, work_ids, document_ids)
      end
    when Array
      object.each { |value| collect_ids(value, work_ids, document_ids) }
    end
  end

  def integer_id(value)
    number = Integer(value, exception: false)
    number if number&.positive?
  end

  def validate_archive_shape!(zip)
    expected = "#{CLEAN_ROOT}/"
    unless archive_contains_prefix?(zip, expected)
      raise ArgumentError, archive_shape_error(expected, zip)
    end

    @targets.each do |target|
      path = "#{CLEAN_ROOT}/#{target}/"
      raise ArgumentError, archive_shape_error(path, zip) unless archive_contains_prefix?(zip, path)
    end
  end

  # ZIP creators are not required to store explicit directory entries. A valid
  # archive may therefore contain `新加坡漢文/clean/.../work.txt` without a
  # separate `新加坡漢文/clean/` record. Test the paths of all entries instead
  # of requiring `Zip::File#find_entry` to find a directory object.
  def archive_contains_prefix?(zip, prefix)
    normalized_prefix = normalize_zip_name(prefix)
    directory_name = normalized_prefix.delete_suffix("/")

    zip.entries.any? do |entry|
      name = normalize_zip_name(entry.name)
      name == directory_name || name.start_with?(normalized_prefix)
    end
  end

  def find_entry_by_normalized_name(zip, wanted_name)
    normalized_wanted = normalize_zip_name(wanted_name)
    zip.entries.find { |entry| normalize_zip_name(entry.name) == normalized_wanted }
  end

  def normalize_zip_name(name)
    raw = name.to_s.dup
    utf8 = raw.dup.force_encoding(Encoding::UTF_8)

    unless utf8.valid_encoding?
      preview = raw.bytes.first(24).map { |byte| format("%02X", byte) }.join(" ")
      raise Encoding::InvalidByteSequenceError,
        "ZIP entry name is not valid UTF-8 (first bytes: #{preview})"
    end

    utf8.unicode_normalize(:nfc).tr("\\", "/").sub(%r{\A\./+}, "")
  end

  def archive_shape_error(expected, zip)
    samples = zip.entries.reject(&:directory?).first(8).map { |entry| normalize_zip_name(entry.name) }
    detail = samples.empty? ? "(archive contains no file entries)" : samples.join(" | ")
    "ZIP does not contain files under #{expected}. Explicit directory entries are not required. " \
      "First file entries: #{detail}"
  end

  def flat_txt_entries(zip, target)
    prefix = "#{CLEAN_ROOT}/#{target}/"
    zip.entries.select do |entry|
      next false if entry.directory?

      name = normalize_zip_name(entry.name)
      next false unless name.start_with?(prefix)

      remainder = name.delete_prefix(prefix)
      !remainder.include?("/") && remainder.downcase.end_with?(".txt")
    end
  end

  def parse_legacy_text(raw_bytes, source_name)
    text, encoding_repairs = decode_utf8_with_audit(raw_bytes, source_name)
    text = text.delete_prefix("\uFEFF")
    lines = text.lines
    first_content = lines.index { |line| !line.match?(/\A[[:space:]]*\z/) }
    raise ArgumentError, "empty TXT file" unless first_content
    raise ArgumentError, "missing leading legacy metadata block" unless lines[first_content].match?(LEGACY_METADATA_LINE)

    metadata_lines = []
    index = first_content
    while index < lines.length && lines[index].match?(LEGACY_METADATA_LINE)
      metadata_lines << lines[index]
      index += 1
    end
    index += 1 while index < lines.length && lines[index].match?(/\A[[:space:]]*\z/)

    metadata = Hash.new { |hash, key| hash[key] = [] }
    metadata_lines.each do |line|
      match = HEADER_PATTERN.match(line.chomp)
      raise ArgumentError, "malformed metadata line: #{line.inspect}" unless match

      metadata[match[1].strip.upcase] << match[2].strip
    end

    title = metadata.fetch("TITLE", []).first.to_s.strip
    authors = metadata.fetch("AUTHOR", []).map(&:strip).reject(&:empty?)
    sources = metadata.fetch("SOURCE", []).map(&:strip).reject(&:empty?)
    nation = metadata.fetch("NATION", []).first.to_s.strip
    body = lines[index..].to_a.join

    raise ArgumentError, "TITLE is blank" if title.empty?
    raise ArgumentError, "AUTHOR is blank" if authors.empty?
    raise ArgumentError, "SOURCE is blank" if sources.empty?
    raise ArgumentError, "NATION is #{nation.inspect}, expected 新加坡" unless nation == "新加坡"
    raise ArgumentError, "body is empty after removing legacy headers" if body.strip.empty?

    LegacyText.new(
      title: title,
      authors: authors,
      sources: sources,
      nation: nation,
      body: body,
      body_sha256: Digest::SHA256.hexdigest(body),
      header_lines: metadata_lines.length,
      encoding_repairs: encoding_repairs
    )
  end

  # Decode corpus text as UTF-8.  The source archive contains one known legacy
  # file with an isolated invalid byte.  We never replace it silently: each
  # removed byte sequence is recorded in the plan and encoding_repairs.csv, and
  # apply mode requires --accept-utf8-repairs.  The original ZIP remains the
  # immutable byte-level source identified by its SHA-256 digest.
  def decode_utf8_with_audit(raw_bytes, source_name)
    text = raw_bytes.to_s.dup.force_encoding(Encoding::UTF_8)
    return [text, []] if text.valid_encoding?

    repairs = []
    repaired = text.scrub do |bad_bytes|
      repairs << {
        "source_entry" => source_name,
        "invalid_bytes_hex" => bad_bytes.bytes.map { |byte| format("%02X", byte) }.join(" "),
        "invalid_byte_count" => bad_bytes.bytesize
      }
      ""
    end

    unless repaired.valid_encoding?
      raise Encoding::InvalidByteSequenceError, "could not repair invalid UTF-8 in #{source_name}"
    end

    [repaired, repairs]
  end

  def short_physical_folder(title, work_id)
    clean = title.to_s.unicode_normalize(:nfc)
      .gsub(UNSAFE_COMPONENT_CHARS, "-")
      .gsub(/[[:space:]]+/, " ")
      .strip
      .sub(/[. ]+\z/, "")
    clean = "work" if clean.empty? || clean.match?(RESERVED_WINDOWS_NAMES)

    graphemes = clean.each_grapheme_cluster.to_a
    if graphemes.length > @max_title_chars
      clean = graphemes.first(@max_title_chars - 1).join + "…"
    end

    folder = "#{clean}__w#{work_id}"
    raise ArgumentError, "generated folder component is too long (#{folder.bytesize} UTF-8 bytes): #{folder}" if folder.bytesize > 180

    folder
  end

  def parent_metadata(collection)
    {
      "schema_version" => SCHEMA_VERSION,
      "work_id" => collection.fetch("parent_work_id"),
      "corpus_root" => ARCHIVE_ROOT,
      "macro_region" => "新加坡",
      "polity" => "新加坡",
      "title" => collection.fetch("title"),
      "categories" => [collection.fetch("title")],
      "is_compilation" => true,
      "known_commentaries" => [],
      "worklist" => collection.fetch("works").map do |work|
        {
          "work_id" => work.fetch("work_id"),
          "title" => work.fetch("title"),
          "edition_id" => work.fetch("edition_id"),
          "edition_label" => work.fetch("edition_label")
        }
      end
    }
  end

  def child_metadata(collection, work)
    parent_reference = {
      "work_id" => collection.fetch("parent_work_id"),
      "title" => collection.fetch("title"),
      "edition_id" => work.fetch("edition_id"),
      "edition_label" => work.fetch("edition_label")
    }

    document = {
      "document_id" => work.fetch("document_id"),
      "file" => "text.txt",
      "path" => work.fetch("target_text"),
      "title" => work.fetch("title"),
      "display_title" => work.fetch("title"),
      "body_start_line" => 1
    }

    {
      "schema_version" => SCHEMA_VERSION,
      "work_id" => work.fetch("work_id"),
      "corpus_root" => ARCHIVE_ROOT,
      "macro_region" => "新加坡",
      "polity" => "新加坡",
      "title" => work.fetch("title"),
      "authors" => work.fetch("authors"),
      "categories" => [collection.fetch("title")],
      "sources" => work.fetch("sources"),
      "is_compilation" => false,
      "known_commentaries" => [],
      "contained_in" => [parent_reference],
      "editions" => [
        {
          "edition_id" => work.fetch("edition_id"),
          "edition_label" => work.fetch("edition_label"),
          "source_work_id" => collection.fetch("parent_work_id"),
          "source_title" => collection.fetch("title"),
          "documents" => [document]
        }
      ]
    }
  end

  def write_plan_reports(plan)
    FileUtils.mkdir_p(@output_root)
    plan_path.write(JSON.pretty_generate(plan) + "\n", encoding: "UTF-8")

    rows = plan.fetch("collections").flat_map do |collection|
      collection.fetch("works").map do |work|
        {
          "collection" => collection.fetch("title"),
          "parent_work_id" => collection.fetch("parent_work_id"),
          "work_id" => work.fetch("work_id"),
          "document_id" => work.fetch("document_id"),
          "edition_id" => work.fetch("edition_id"),
          "edition_label" => work.fetch("edition_label"),
          "full_title" => work.fetch("title"),
          "authors" => Array(work.fetch("authors")).join("; "),
          "sources" => Array(work.fetch("sources")).join("; "),
          "source_entry" => work.fetch("source_entry"),
          "source_sha256" => work.fetch("source_sha256"),
          "body_sha256" => work.fetch("body_sha256"),
          "target_folder" => work.fetch("target_folder"),
          "target_text" => work.fetch("target_text"),
          "target_metadata" => work.fetch("target_metadata"),
          "title_characters" => work.fetch("title_characters"),
          "physical_folder_bytes" => work.fetch("physical_folder_bytes"),
          "encoding_repair_count" => work.fetch("encoding_repair_count"),
          "encoding_repairs" => Array(work.fetch("encoding_repairs")).map { |repair| repair.fetch("invalid_bytes_hex") }.join("; ")
        }
      end
    end
    write_csv(plan_csv_path, rows)
    repair_rows = plan.fetch("collections").flat_map do |collection|
      collection.fetch("works").flat_map do |work|
        Array(work.fetch("encoding_repairs", [])).map do |repair|
          repair.merge(
            "collection" => collection.fetch("title"),
            "work_id" => work.fetch("work_id"),
            "document_id" => work.fetch("document_id"),
            "title" => work.fetch("title"),
            "source_sha256" => work.fetch("source_sha256")
          )
        end
      end
    end
    write_csv(
      encoding_repairs_path,
      repair_rows,
      headers: %w[collection work_id document_id title source_entry source_sha256 invalid_bytes_hex invalid_byte_count]
    )
    write_validation_errors

    summary_path.write(JSON.pretty_generate(plan.fetch("summary").merge(
      "source_zip_sha256" => plan.fetch("source_zip_sha256"),
      "id_inventory" => plan.fetch("id_inventory")
    )) + "\n", encoding: "UTF-8")

    progress "wrote plan #{plan_path}"
    progress "wrote review table #{plan_csv_path}"
  end

  def load_plan
    JSON.parse(plan_path.read(encoding: "UTF-8"))
  rescue JSON::ParserError => error
    raise ArgumentError, "Invalid plan JSON: #{error.message}"
  end

  def validate_plan_before_apply!(plan)
    raise ArgumentError, "Unsupported plan version #{plan['plan_version']}" unless plan["plan_version"].to_i == PLAN_VERSION
    raise ArgumentError, "Plan source ZIP digest no longer matches" unless plan.fetch("source_zip_sha256") == sha256_file(@source_zip)
    raise ArgumentError, "Plan target list does not match CLI targets" unless Array(plan.fetch("targets")).sort == @targets.sort

    repair_count = plan.dig("summary", "invalid_utf8_sequences_removed").to_i
    if repair_count.positive? && !@accept_utf8_repairs
      raise ArgumentError, <<~MESSAGE.strip
        Plan contains #{repair_count} invalid UTF-8 byte sequence repair(s).
        Review #{encoding_repairs_path}, then rerun apply mode with
        --accept-utf8-repairs if the proposed byte removals are acceptable.
      MESSAGE
    end

    planned_work_ids = plan.fetch("collections").flat_map do |collection|
      [collection.fetch("parent_work_id")] + collection.fetch("works").map { |work| work.fetch("work_id") }
    end.to_set
    planned_document_ids = plan.fetch("collections").flat_map do |collection|
      collection.fetch("works").map { |work| work.fetch("document_id") }
    end.to_set

    inventory = build_id_inventory
    work_collisions = planned_work_ids & inventory.fetch(:work_ids)
    document_collisions = planned_document_ids & inventory.fetch(:document_ids)

    unless work_collisions.empty?
      raise ArgumentError, "Planned work IDs are now in use: #{work_collisions.to_a.sort.first(20).join(', ')}. Re-run with --replan."
    end
    unless document_collisions.empty?
      raise ArgumentError, "Planned document IDs are now in use: #{document_collisions.to_a.sort.first(20).join(', ')}. Re-run with --replan."
    end
  end

  def write_output_zip(plan)
    FileUtils.mkdir_p(@output_zip.dirname)
    FileUtils.rm_f(@output_zip)

    transformed_sources = plan.fetch("collections").flat_map { |collection| collection.fetch("works").map { |work| work.fetch("source_entry") } }.to_set
    replaced_metadata = plan.fetch("collections").map { |collection| collection.fetch("metadata_path") }.to_set

    Zip::File.open(@source_zip.to_s) do |source|
      Zip::File.open(@output_zip.to_s, create: true) do |output|
        written = Set.new

        source.entries.sort_by { |entry| normalize_zip_name(entry.name) }.each do |entry|
          entry_name = normalize_zip_name(entry.name)
          next if transformed_sources.include?(entry_name)
          next if replaced_metadata.include?(entry_name)

          copy_zip_entry(entry, output, written)
        end

        plan.fetch("collections").each do |collection|
          write_zip_text(output, written, collection.fetch("metadata_path"), JSON.pretty_generate(parent_metadata(collection)) + "\n")

          collection.fetch("works").each do |work|
            ensure_zip_directory(output, written, work.fetch("target_folder") + "/")
            source_entry = find_entry_by_normalized_name(source, work.fetch("source_entry"))
            raise "Missing source entry during apply: #{work.fetch('source_entry')}" unless source_entry

            source_name = normalize_zip_name(source_entry.name)
            parsed = parse_legacy_text(source_entry.get_input_stream.read, source_name)
            raise "Body changed after planning: #{source_name}" unless parsed.body_sha256 == work.fetch("body_sha256")
            unless parsed.encoding_repairs == Array(work.fetch("encoding_repairs", []))
              raise "UTF-8 repair plan changed after planning: #{source_name}"
            end

            write_zip_text(output, written, work.fetch("target_text"), parsed.body)
            write_zip_text(output, written, work.fetch("target_metadata"), JSON.pretty_generate(child_metadata(collection, work)) + "\n")
          end
        end
      end
    end
  end

  def copy_zip_entry(entry, output, written)
    entry_name = normalize_zip_name(entry.name)
    return if written.include?(entry_name)

    if entry.directory?
      ensure_zip_directory(output, written, entry_name)
    else
      ensure_zip_parent_directories(output, written, entry_name)
      output.get_output_stream(entry_name) { |io| io.write(entry.get_input_stream.read) }
      written << entry_name
    end
  end

  def write_zip_text(output, written, name, text)
    raise "Duplicate ZIP entry #{name}" if written.include?(name)

    ensure_zip_parent_directories(output, written, name)
    output.get_output_stream(name) { |io| io.write(text.encode(Encoding::UTF_8)) }
    written << name
  end

  def ensure_zip_parent_directories(output, written, name)
    parts = name.split("/")
    return if parts.length < 2

    current = ""
    parts[0...-1].each do |part|
      current = current.empty? ? "#{part}/" : "#{current}#{part}/"
      ensure_zip_directory(output, written, current)
    end
  end

  def ensure_zip_directory(output, written, name)
    directory = name.end_with?("/") ? name : "#{name}/"
    return if written.include?(directory)

    output.mkdir(directory.delete_suffix("/"))
    written << directory
  rescue Zip::EntryExistsError
    written << directory
  end

  def verify_output_zip!(plan)
    progress "verifying repaired archive"
    expected_work_ids = Set.new
    expected_document_ids = Set.new

    Zip::File.open(@output_zip.to_s) do |zip|
      plan.fetch("collections").each do |collection|
        immediate_txt = flat_txt_entries(zip, collection.fetch("title"))
        raise "Verification failed: flat TXT files remain in #{collection.fetch('title')}" unless immediate_txt.empty?

        parent_entry = find_entry_by_normalized_name(zip, collection.fetch("metadata_path"))
        raise "Verification failed: missing #{collection.fetch('metadata_path')}" unless parent_entry
        parent = JSON.parse(parent_entry.get_input_stream.read)
        raise "Verification failed: parent is not a compilation" unless parent["is_compilation"] == true
        raise "Verification failed: worklist count mismatch" unless parent.fetch("worklist").length == collection.fetch("works").length
        expected_work_ids << parent.fetch("work_id")

        collection.fetch("works").each do |work|
          metadata_entry = find_entry_by_normalized_name(zip, work.fetch("target_metadata"))
          text_entry = find_entry_by_normalized_name(zip, work.fetch("target_text"))
          raise "Verification failed: missing #{work.fetch('target_metadata')}" unless metadata_entry
          raise "Verification failed: missing #{work.fetch('target_text')}" unless text_entry

          metadata = JSON.parse(metadata_entry.get_input_stream.read)
          body = text_entry.get_input_stream.read.force_encoding(Encoding::UTF_8)
          raise "Verification failed: invalid UTF-8 body #{work.fetch('target_text')}" unless body.valid_encoding?
          raise "Verification failed: title changed for #{work.fetch('source_entry')}" unless metadata.fetch("title") == work.fetch("title")
          raise "Verification failed: body changed for #{work.fetch('source_entry')}" unless Digest::SHA256.hexdigest(body) == work.fetch("body_sha256")
          raise "Verification failed: legacy header remains in #{work.fetch('target_text')}" if body.lines.first.to_s.match?(LEGACY_METADATA_LINE)

          work_id = metadata.fetch("work_id")
          document_id = metadata.fetch("editions").first.fetch("documents").first.fetch("document_id")
          raise "Verification failed: duplicate work_id #{work_id}" if expected_work_ids.include?(work_id)
          raise "Verification failed: duplicate document_id #{document_id}" if expected_document_ids.include?(document_id)
          expected_work_ids << work_id
          expected_document_ids << document_id
        end
      end
    end

    progress "verified #{@output_zip} (#{File.size(@output_zip)} bytes)"
  end

  def write_repaired_tree(plan)
    root = @output_root.join("repaired_tree")
    FileUtils.rm_rf(root)
    FileUtils.mkdir_p(root)

    Zip::File.open(@output_zip.to_s) do |zip|
      plan.fetch("collections").each do |collection|
        prefix = "#{CLEAN_ROOT}/#{collection.fetch('title')}/"
        zip.entries.select { |entry| normalize_zip_name(entry.name).start_with?(prefix) }.each do |entry|
          entry_name = normalize_zip_name(entry.name)
          destination = root.join(entry_name).cleanpath
          root_prefix = root.cleanpath.to_s + File::SEPARATOR
          unless destination.to_s.start_with?(root_prefix)
            raise "Unsafe ZIP path while extracting repaired tree: #{entry_name}"
          end
          if entry.directory?
            FileUtils.mkdir_p(destination)
          else
            FileUtils.mkdir_p(destination.dirname)
            File.binwrite(destination, entry.get_input_stream.read)
          end
        end
      end
    end

    progress "wrote extractable repaired folders to #{root}"
  end

  def write_install_notes(plan)
    stamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
    corpus = @corpus_root || Pathname("/PATH/TO/corpus")
    tree = @output_root.join("repaired_tree")
    lines = []
    lines << "REVIEW THESE COMMANDS BEFORE RUNNING THEM."
    lines << ""
    lines << "The script intentionally does not replace live corpus folders automatically."
    lines << "The source ZIP is a snapshot, so an automatic replacement could clobber newer edits."
    lines << ""
    plan.fetch("collections").each do |collection|
      title = collection.fetch("title")
      live = corpus.join(CLEAN_ROOT, title)
      repaired = tree.join(CLEAN_ROOT, title)
      backup = live.dirname.join("#{title}.before_folderisation_#{stamp}")
      lines << "mv #{shell_quote(live.to_s)} #{shell_quote(backup.to_s)}"
      lines << "cp -a #{shell_quote(repaired.to_s)} #{shell_quote(live.to_s)}"
      lines << ""
    end
    lines << "After checking the viewer and metadata, rebuild the manifest:"
    lines << "  bin/rails corpus_search:rebuild_manifest"
    install_notes_path.write(lines.join("\n") + "\n", encoding: "UTF-8")
  end

  def print_summary(plan)
    summary = plan.fetch("summary")
    ids = plan.fetch("id_inventory")
    progress "mode=#{@apply ? 'APPLY' : 'DRY RUN'} collections=#{summary.fetch('collections')} contained_works=#{summary.fetch('contained_works')} documents=#{summary.fetch('documents')}"
    progress "new work IDs #{ids.fetch('first_new_work_id')}..#{ids.fetch('last_new_work_id')}; new document IDs #{ids.fetch('first_new_document_id')}..#{ids.fetch('last_new_document_id')}"
    progress "full titles remain in metadata; physical folder names are limited to #{@max_title_chars} grapheme clusters plus the stable work ID"
    repair_count = summary.fetch("invalid_utf8_sequences_removed", 0).to_i
    if repair_count.positive?
      progress "WARNING: #{repair_count} invalid UTF-8 byte sequence(s) require review in #{encoding_repairs_path}"
    end
    progress "dry-run reports: #{@output_root}" unless @apply
  end

  def write_csv(path, rows, headers: nil)
    headers ||= rows.flat_map(&:keys).uniq

    # Excel on Windows commonly opens a .csv using the local ANSI code page
    # unless the file starts with a UTF-8 byte-order mark.  The corpus values
    # are still ordinary UTF-8; the BOM only tells spreadsheet software how
    # to decode those bytes.  CRLF rows also make direct Excel opening more
    # predictable without changing the represented data.
    File.open(path, "wb") do |io|
      io.write("\xEF\xBB\xBF".b)
      csv = CSV.new(io, write_headers: true, headers: headers, row_sep: "\r\n")
      rows.each { |row| csv << headers.map { |header| row[header] } }
    end
  end

  def write_validation_errors
    write_csv(validation_errors_path, @validation_errors) unless @validation_errors.empty?
    if @validation_errors.empty?
      write_csv(validation_errors_path, [], headers: %w[collection path error_type message])
    end
  end

  def write_scan_errors
    write_csv(scan_errors_path, @scan_errors)
  end

  def error_row(collection, path, type, message)
    {
      "collection" => collection,
      "path" => path,
      "error_type" => type,
      "message" => message
    }
  end

  def scan_error_row(path, error, operation = "read")
    {
      "path" => path.to_s,
      "operation" => operation,
      "error_class" => error.class.name,
      "message" => error.message
    }
  end

  def maybe_progress(count, label)
    return unless @progress_every.positive?
    return unless (count % @progress_every).zero?

    progress "#{label}: #{count}"
  end

  def progress(message)
    warn "[singapore-folderisation] #{Time.now.utc.iso8601} #{message}"
  end

  def sha256_file(path)
    Digest::SHA256.file(path).hexdigest
  end

  def shell_quote(value)
    "'#{value.to_s.gsub("'", %q('"'"'))}'"
  end

  def plan_path
    @output_root.join("plan.json")
  end

  def plan_csv_path
    @output_root.join("folderisation_plan.csv")
  end

  def summary_path
    @output_root.join("summary.json")
  end

  def validation_errors_path
    @output_root.join("validation_errors.csv")
  end

  def scan_errors_path
    @output_root.join("id_scan_errors.csv")
  end

  def encoding_repairs_path
    @output_root.join("encoding_repairs.csv")
  end

  def install_notes_path
    @output_root.join("INSTALL_COMMANDS.txt")
  end
end

if $PROGRAM_NAME == __FILE__
  options = {
    source_zip: nil,
    corpus_root: ENV["CORPUS_ROOT"].to_s.strip.empty? ? File.expand_path("../corpus", Dir.pwd) : ENV["CORPUS_ROOT"],
    output_root: File.expand_path("tmp/singapore_folderisation", Dir.pwd),
    output_zip: File.expand_path("tmp/singapore_folderisation/新加坡漢文_folderised.zip", Dir.pwd),
    apply: false,
    replan: false,
    extract_tree: true,
    accept_utf8_repairs: false,
    max_title_chars: SingaporeFlatCollectionFolderiser::DEFAULT_TITLE_CHARS,
    work_id_start: nil,
    document_id_start: nil,
    id_registry: nil,
    read_retries: SingaporeFlatCollectionFolderiser::DEFAULT_READ_RETRIES,
    progress_every: 10_000,
    targets: SingaporeFlatCollectionFolderiser::TARGETS.dup
  }

  parser = OptionParser.new do |opts|
    opts.banner = <<~TEXT
      Usage:
        bundle exec ruby script/folderise_singapore_flat_collections.rb \
          --source-zip /path/to/新加坡漢文.zip

      Default mode is a dry run. It writes plan.json and folderisation_plan.csv.
      Add --apply only after reviewing those files.
    TEXT

    opts.on("--source-zip PATH", "Source 新加坡漢文.zip (required)") { |value| options[:source_zip] = value }
    opts.on("--corpus-root PATH", "Live corpus root used only when writing installation notes") { |value| options[:corpus_root] = value }
    opts.on("--id-registry PATH", "Authoritative metadata_id_registry.csv used to allocate new stable IDs") { |value| options[:id_registry] = value }
    opts.on("--output PATH", "Report/output directory") do |value|
      options[:output_root] = File.expand_path(value)
      options[:output_zip] = File.join(options[:output_root], "新加坡漢文_folderised.zip")
    end
    opts.on("--output-zip PATH", "Repaired full archive path") { |value| options[:output_zip] = File.expand_path(value) }
    opts.on("--target NAME", "Target collection; repeatable (defaults to the two known flat folders)") do |value|
      options[:targets] = [] if options[:targets] == SingaporeFlatCollectionFolderiser::TARGETS
      options[:targets] << value
    end
    opts.on("--max-title-chars N", Integer, "Physical title prefix length; full title remains in JSON (default 36)") { |value| options[:max_title_chars] = value }
    opts.on("--work-id-start N", Integer, "Explicit first new work ID; use only with independently verified IDs") { |value| options[:work_id_start] = value }
    opts.on("--document-id-start N", Integer, "Explicit first new document ID; use only with independently verified IDs") { |value| options[:document_id_start] = value }
    opts.on("--read-retries N", Integer, "Retries for transient WSL/OneDrive directory errors (default 5)") { |value| options[:read_retries] = value }
    opts.on("--progress-every N", Integer, "ID-registry progress interval (default 10000)") { |value| options[:progress_every] = value }
    opts.on("--apply", "Create repaired archive and repaired_tree after validation") { options[:apply] = true }
    opts.on("--accept-utf8-repairs", "Apply reviewed removal of invalid UTF-8 byte sequences listed in encoding_repairs.csv") { options[:accept_utf8_repairs] = true }
    opts.on("--replan", "Ignore an existing plan.json and allocate a fresh plan") { options[:replan] = true }
    opts.on("--no-extract-tree", "Do not write the repaired_tree directory") { options[:extract_tree] = false }
    opts.on("-h", "--help", "Show this help") do
      puts opts
      exit
    end
  end

  parser.parse!
  abort parser.to_s unless options[:source_zip]

  SingaporeFlatCollectionFolderiser.new(options).run
end
