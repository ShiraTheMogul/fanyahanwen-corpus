# frozen_string_literal: true

require "json"
require "pathname"
require "set"

# Reads the per-work metadata.json files that now sit beside corpus .txt files.
#
# Rule of thumb:
#   work folder/
#     metadata.json
#     work__juan_01.txt
#
# The old leading # metadata headers are kept only as a legacy fallback. New
# viewer/search code should ask this class for display/search metadata and use
# the .txt file as body text.
class CorpusMetadataStore
  DISPLAY_LABELS = {
    "work_id" => "Work ID",
    "document_id" => "Document ID",
    "title" => "Title",
    "work_base_title" => "Work",
    "authors" => "Author",
    "editors" => "Editor",
    "contributors" => "Contributors",
    "date_label" => "Date",
    "corpus_root" => "Corpus root",
    "macro_region" => "Macro region",
    "period" => "Period",
    "polity" => "Polity",
    "region" => "Region",
    "categories" => "Categories",
    "source_categories" => "Ws Categories",
    "sources" => "Sources",
    "rights" => "Rights",
    "known_commentaries" => "Known commentaries",
    "is_compilation" => "Compilation",
    "edition" => "Edition",
    "edition_label" => "Edition",
    "material_type" => "Text type",
    "reconstruction" => "Reconstruction",
    "reconstruction_scope" => "Reconstruction scope",
    "reconstruction_basis" => "Reconstruction basis",
    "source_document_id" => "Source document ID",
    "page_title" => "Page title",
    "chapter" => "Chapter",
    "file" => "File",
    "path" => "Path"
  }.freeze

  LEGACY_LABELS = {
    "TITLE" => "Title",
    "PAGE_TITLE" => "Page title",
    "WORK_TITLE" => "Work",
    "WORK_BASE_TITLE" => "Work",
    "AUTHOR" => "Author",
    "DATE" => "Date",
    "TIMES" => "Time and/or Location",
    "TIME" => "Time and/or Location",
    "NATION" => "Corpus root",
    "REGION" => "Region",
    "CATEGORY" => "Categories",
    "CATEGORIES" => "Categories",
    "SOURCE_CATEGORIES" => "Ws Categories",
    "WS_CATEGORIES" => "Ws Categories"
  }.freeze

  attr_reader :root

  def initialize(root:, fs: nil, logger: default_logger)
    root = root.to_s
    raise ArgumentError, "Corpus root is empty" if root.strip.empty?

    @root = Pathname(File.realpath(root))
    @fs = fs || CorpusFs.new(root: root)
    @logger = logger
    @cache = {}
  end

  def metadata_path_for(rel_path)
    abs = Pathname(@fs.resolve(rel_path))
    dir = abs.file? ? abs.dirname : abs

    loop do
      path = dir.join("metadata.json")
      return path if path.file?
      break if dir == @root
      break unless dir.to_s.start_with?(@root.to_s + File::SEPARATOR)

      dir = dir.parent
    end

    nil
  rescue SecurityError, SystemCallError
    nil
  end

  def metadata_relative_path_for(rel_path)
    path = metadata_path_for(rel_path)
    return nil unless path

    path.relative_path_from(@root).to_s.tr("\\", "/")
  rescue ArgumentError
    nil
  end

  def metadata_for_path(rel_path)
    path = metadata_path_for(rel_path)
    return {} unless path

    read_json(path)
  end

  # Metadata files that can change the searchable representation of a document.
  # Parent compilation dates are deliberately separate from child-work dates, but
  # they still belong in the manifest record. Including both files in the cache
  # fingerprint means editing a compilation date invalidates its child rows.
  def metadata_dependency_paths_for(rel_path)
    primary = metadata_path_for(rel_path)
    return [] unless primary

    [primary, compilation_metadata_path_for(primary)].compact.uniq
  end

  # Return the explicitly linked enclosing compilation above the current work.
  # The current work keeps its own chronology; these fields preserve the
  # separate date of the compilation that contains it. A directory ancestor is
  # not enough evidence by itself: the child must name the compilation in
  # `contained_in`, or the compilation must list the child work_id in `worklist`.
  def compilation_context_for_path(rel_path)
    current_metadata_path = metadata_path_for(rel_path)
    return {} unless current_metadata_path

    compilation_path = compilation_metadata_path_for(current_metadata_path)
    return {} unless compilation_path

    metadata = read_json(compilation_path)
    {
      "compilation_work_id" => integer_or_nil(metadata["work_id"]),
      "compilation_title" => first_present(metadata["work_base_title"], metadata["title"]),
      "compilation_period" => metadata["period"].to_s,
      "compilation_polity" => metadata["polity"].to_s,
      "compilation_date_text" => metadata["date_label"].to_s,
      "compilation_year_start" => integer_or_nil(metadata["year_start"] || metadata["year"]),
      "compilation_year_end" => integer_or_nil(metadata["year_end"] || metadata["year"])
    }
  rescue SecurityError, SystemCallError, JSON::ParserError
    {}
  end

  def work_folder?(rel_path)
    path = metadata_path_for(rel_path)
    return false unless path

    document_paths_for_work_folder(rel_path).any?
  end

  def document_paths_for_work_folder(rel_path)
    metadata_path = metadata_path_for(rel_path)
    return [] unless metadata_path

    folder_rel = rel_path.to_s.tr('\\', '/').sub(%r{/+\z}, '')
    folder_rel = '' if folder_rel == '.'
    folder_abs = metadata_path.dirname
    work = read_json(metadata_path)

    paths = []
    document_hashes_for(work).each do |doc|
      next unless doc.is_a?(Hash)

      explicit = doc['path'].to_s.tr('\\', '/').sub(%r{\A/+}, '')
      if explicit.present? && @root.join(explicit).file?
        paths << explicit
        next
      end

      file = doc['file'].to_s
      next if file.blank?

      candidate = [folder_rel, file].reject(&:blank?).join('/')
      paths << candidate if @root.join(candidate).file?
    end

    if paths.empty? && folder_abs.directory?
      Dir.children(folder_abs).sort.each do |name|
        next unless name.downcase.end_with?('.txt')

        paths << [folder_rel, name].reject(&:blank?).join('/')
      end
    end

    paths.uniq
  rescue SystemCallError, JSON::ParserError
    []
  end

  def editable_metadata_values_for_path(rel_path)
    metadata = metadata_for_path(rel_path)
    return {} if metadata.empty?

    {
      'title' => metadata['title'].to_s,
      'authors' => names_string(metadata['authors']),
      'date_label' => metadata['date_label'].to_s,
      'corpus_root' => metadata['corpus_root'].to_s,
      'period' => metadata['period'].to_s,
      'polity' => metadata['polity'].to_s,
      'region' => metadata['region'].to_s,
      'categories' => Array(metadata['categories']).map(&:to_s).reject(&:blank?).join("\n"),
      'sources' => Array(metadata['sources']).map { |source| source.is_a?(Hash) ? source['citation'].to_s.presence || source.to_json : source.to_s }.reject(&:blank?).join("\n")
    }
  end

  def document_metadata_for_path(rel_path)
    work = metadata_for_path(rel_path)
    return {} if work.empty?

    document = find_document_metadata(work, rel_path)
    merge_hashes(work_metadata_only(work), document)
  end

  def search_metadata_for_path(rel_path)
    metadata = document_metadata_for_path(rel_path)
    path_metadata = metadata_from_path(rel_path)
    categories = Array(metadata["categories"]).map(&:to_s).map(&:strip).reject(&:blank?).uniq
    compilation = compilation_context_for_path(rel_path)

    {
      "work_id" => integer_or_nil(metadata["work_id"]),
      "document_id" => integer_or_nil(metadata["document_id"]),
      "title" => first_present(metadata["title"], metadata["page_title"], File.basename(rel_path.to_s, ".txt")),
      "work" => first_present(metadata["work_base_title"], metadata["work_title"], metadata["title"], File.basename(File.dirname(rel_path.to_s))),
      "author" => names_string(metadata["authors"]),
      "date_text" => metadata["date_label"].to_s,
      "nation" => first_present(metadata["corpus_root"], path_metadata["nation"]),
      "corpus_root" => first_present(metadata["corpus_root"], path_metadata["nation"]),
      "macro_region" => metadata["macro_region"].to_s,
      "period" => metadata["period"].to_s,
      "polity" => metadata["polity"].to_s,
      "region" => metadata["region"].to_s,
      # Keep the legacy joined scalar while every new index consumes the array.
      "category" => categories.join("; "),
      "categories" => categories,
      "year_start" => integer_or_nil(metadata["year_start"] || metadata["year"]),
      "year_end" => integer_or_nil(metadata["year_end"] || metadata["year"])
    }.merge(compilation)
  end

  def display_entries_for_path(rel_path)
    metadata = document_metadata_for_path(rel_path)
    return [] if metadata.empty?

    DISPLAY_LABELS.filter_map do |key, label|
      value = metadata[key]
      next if blank_value?(value)

      [label, display_value(value)]
    end
  end

  # Legacy compatibility for old files/tickets that still contain # headers.
  def legacy_entries_from_text(raw)
    document = CorpusSearch::DocumentReader.parse(raw)
    document.metadata_entries.map do |key, value|
      [legacy_label(key), value]
    end
  end

  def document_hashes_for(work)
    docs = Array(work['documents'])
    docs.concat(Array(work['editions']).flat_map { |edition| Array(edition['documents']) })
    docs.concat(Array(work['translations']).flat_map { |translation| Array(translation['documents']) })
    docs
  end

  private

  def compilation_metadata_path_for(current_metadata_path)
    current_metadata = read_json(current_metadata_path)
    child_work_id = integer_or_nil(current_metadata["work_id"])
    declared_parent_ids = Array(current_metadata["contained_in"]).filter_map do |relation|
      next unless relation.is_a?(Hash)

      integer_or_nil(relation["work_id"])
    end.uniq

    dir = Pathname(current_metadata_path).dirname.parent
    while dir == @root || dir.to_s.start_with?(@root.to_s + File::SEPARATOR)
      candidate = dir.join("metadata.json")
      if candidate.file?
        metadata = read_json(candidate)
        if truthy_metadata_value?(metadata["is_compilation"])
          candidate_work_id = integer_or_nil(metadata["work_id"])
          child_listed = child_work_id && Array(metadata["worklist"]).any? do |entry|
            entry.is_a?(Hash) && integer_or_nil(entry["work_id"]) == child_work_id
          end
          parent_declared = candidate_work_id && declared_parent_ids.include?(candidate_work_id)
          return candidate if parent_declared || child_listed
        end
      end

      break if dir == @root
      dir = dir.parent
    end

    nil
  end

  def read_json(path)
    key = path.to_s
    @cache.fetch(key) do
      raw = path.binread.force_encoding(Encoding::UTF_8)
      raise JSON::ParserError, "invalid UTF-8" unless raw.valid_encoding?

      # Corpus metadata may be UTF-8 with BOM. Ruby's JSON parser does not
      # consume U+FEFF itself, so remove only the leading encoding marker.
      @cache[key] = JSON.parse(raw.sub(/\A\uFEFF/, ""))
    rescue JSON::ParserError => e
      @logger&.warn("[corpus_metadata_store] invalid JSON #{relative_display(path)}: #{e.message}")
      @cache[key] = {}
    rescue SystemCallError => e
      @logger&.warn("[corpus_metadata_store] cannot read #{relative_display(path)}: #{e.class}: #{e.message}")
      @cache[key] = {}
    end
  end

  def find_document_metadata(work, rel_path)
    candidates = []
    Array(work["documents"]).each do |document|
      candidates << [{}, document]
    end
    Array(work["editions"]).each do |edition|
      parent = edition.to_h.except("documents")
      Array(edition["documents"]).each { |document| candidates << [parent, document] }
    end
    Array(work["translations"]).each do |translation|
      parent = translation.to_h.except("documents")
      Array(translation["documents"]).each { |document| candidates << [parent, document] }
    end

    normalized_path = rel_path.to_s.tr("\\", "/")
    file_name = File.basename(normalized_path)
    pair = candidates.find { |_parent, doc| doc.is_a?(Hash) && doc["path"].to_s == normalized_path } ||
      candidates.find { |_parent, doc| doc.is_a?(Hash) && doc["file"].to_s == file_name }
    return {} unless pair

    parent, document = pair
    merge_hashes(parent, document)
  end

  def work_metadata_only(work)
    work.except("documents", "worklist", "editions", "translations")
  end

  def merge_hashes(work, document)
    work.merge(document.to_h) do |_key, work_value, document_value|
      blank_value?(document_value) ? work_value : document_value
    end
  end

  def display_value(value)
    case value
    when Array
      value.map { |item| display_value(item) }.reject(&:blank?).join("; ")
    when Hash
      if value.key?("name") && value.key?("role")
        "#{value['name']} (#{value['role']})"
      else
        value.map { |key, item| "#{key}: #{display_value(item)}" }.join("; ")
      end
    else
      value.to_s
    end
  end

  def names_string(value)
    Array(value).map do |item|
      item.is_a?(Hash) ? item["name"].to_s : item.to_s
    end.reject(&:blank?).join("; ")
  end

  def first_present(*values)
    values.find { |value| value.to_s.strip.present? }.to_s
  end

  def blank_value?(value)
    value.nil? || value == false || (value.respond_to?(:empty?) && value.empty?) || value.to_s.strip.empty?
  end

  def truthy_metadata_value?(value)
    value == true || value.to_s.strip.casecmp("true").zero? || value.to_s == "1"
  end

  def integer_or_nil(value)
    Integer(value) if value.to_s.match?(/\A-?\d+\z/)
  rescue ArgumentError, TypeError
    nil
  end

  def metadata_from_path(relative_path)
    parts = relative_path.to_s.split("/")
    {
      "nation" => parts.first.to_s
    }
  end

  def legacy_label(key)
    normalized = key.to_s.strip.upcase
    LEGACY_LABELS.fetch(normalized) { normalized.downcase.split("_").map(&:capitalize).join(" ") }
  end

  def relative_display(path)
    Pathname(path).relative_path_from(@root).to_s
  rescue ArgumentError
    path.to_s
  end

  def default_logger
    Rails.logger if defined?(Rails) && Rails.respond_to?(:logger)
  end
end
