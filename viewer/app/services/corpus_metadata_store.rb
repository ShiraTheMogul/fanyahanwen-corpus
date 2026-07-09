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
    path = dir.join("metadata.json")
    path.file? ? path : nil
  rescue SecurityError, SystemCallError
    nil
  end

  def metadata_for_path(rel_path)
    path = metadata_path_for(rel_path)
    return {} unless path

    read_json(path)
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

    {
      "title" => first_present(metadata["title"], metadata["page_title"], File.basename(rel_path.to_s, ".txt")),
      "work" => first_present(metadata["work_base_title"], metadata["work_title"], metadata["title"], File.basename(File.dirname(rel_path.to_s))),
      "author" => names_string(metadata["authors"]),
      "date_text" => metadata["date_label"].to_s,
      "nation" => first_present(metadata["corpus_root"], path_metadata["nation"]),
      "period" => first_present(metadata["period"], path_metadata["period"]),
      "region" => first_present(metadata["region"], metadata["polity"], path_metadata["region"]),
      "category" => Array(metadata["categories"]).join("; "),
      "year_start" => integer_or_nil(metadata["year_start"] || metadata["year"]),
      "year_end" => integer_or_nil(metadata["year_end"] || metadata["year"])
    }
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

  private

  def read_json(path)
    key = path.to_s
    @cache.fetch(key) do
      @cache[key] = JSON.parse(path.read(encoding: "UTF-8"))
    rescue JSON::ParserError => e
      @logger&.warn("[corpus_metadata_store] invalid JSON #{relative_display(path)}: #{e.message}")
      @cache[key] = {}
    rescue SystemCallError => e
      @logger&.warn("[corpus_metadata_store] cannot read #{relative_display(path)}: #{e.class}: #{e.message}")
      @cache[key] = {}
    end
  end

  def find_document_metadata(work, rel_path)
    docs = Array(work["documents"])
    docs.concat(Array(work["editions"]).flat_map { |edition| Array(edition["documents"]) })

    normalized_path = rel_path.to_s.tr("\\", "/")
    file_name = File.basename(normalized_path)

    docs.find { |doc| doc.is_a?(Hash) && doc["path"].to_s == normalized_path } ||
      docs.find { |doc| doc.is_a?(Hash) && doc["file"].to_s == file_name } ||
      {}
  end

  def work_metadata_only(work)
    work.except("documents", "worklist", "editions")
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

  def integer_or_nil(value)
    Integer(value) if value.to_s.match?(/\A-?\d+\z/)
  rescue ArgumentError, TypeError
    nil
  end

  def metadata_from_path(relative_path)
    parts = relative_path.to_s.split("/")
    layer_index = parts.index("clean") || parts.index("raw")
    after_clean = layer_index ? parts[(layer_index + 1)..] : parts

    {
      "nation" => parts.first.to_s,
      "period" => after_clean && after_clean.length > 1 ? after_clean.first.to_s : "",
      "region" => after_clean && after_clean.length > 2 ? after_clean[1].to_s : ""
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
