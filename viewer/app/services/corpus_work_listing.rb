# frozen_string_literal: true

require "pathname"

# Lightweight catalogue for one corpus work folder.
#
# The existing reader intentionally treats small multi-document works as one
# continuous text. Very large compilations cannot be rendered that way: reading
# thousands of source files creates multi-megabyte responses and can hold a web
# request open for minutes. This object derives the document list from the
# existing metadata without reading document bodies or stat-ing every declared
# document. Missing files are handled by the existing reader when opened.
class CorpusWorkListing
  Page = Struct.new(:paths, :page, :per_page, :total, :total_pages, keyword_init: true)

  def initialize(root:, fs:, metadata_store:, rel_path:)
    @root = Pathname(File.realpath(root.to_s))
    @fs = fs
    @metadata_store = metadata_store
    @rel_path = normalize_rel(rel_path)
    @abs_path = Pathname(@fs.resolve(@rel_path))
  end

  def work_folder?
    own_metadata? && document_count.positive?
  end

  def document_count
    document_paths.length
  end

  # Continuous work rendering is deliberately bounded by both document count
  # and source bytes. A two-juan work can still contain several megabytes of
  # text, and the corpus reader expands every source character into indexed HTML.
  # Only stat the small candidate set: callers should check this method instead
  # of reading bodies to discover whether a work is safe to inline.
  def inline_renderable?(document_limit:, byte_limit:)
    return false if document_count > document_limit.to_i

    budget = [byte_limit.to_i, 0].max
    return false if budget.zero?

    total = 0
    document_paths.each do |document_path|
      absolute = @fs.resolve(document_path)
      total += File.size(absolute)
      return false if total > budget
    rescue Errno::ENOENT, Errno::EACCES, SecurityError
      next
    end

    true
  end

  def page(page:, per_page:)
    page = [page.to_i, 1].max
    per_page = [[per_page.to_i, 1].max, 500].min
    paths = document_paths
    total = paths.length
    total_pages = [(total.to_f / per_page).ceil, 1].max
    page = [page, total_pages].min

    Page.new(
      paths: paths.slice((page - 1) * per_page, per_page) || [],
      page: page,
      per_page: per_page,
      total: total,
      total_pages: total_pages
    )
  end

  private

  def own_metadata?
    relative = @metadata_store.metadata_relative_path_for(@rel_path).to_s.tr("\\", "/")
    return false if relative.empty?

    metadata_dir = File.dirname(relative)
    metadata_dir = "" if metadata_dir == "."
    metadata_dir == @rel_path
  end

  def document_paths
    @document_paths ||= begin
      metadata = @metadata_store.metadata_for_path(@rel_path)
      from_metadata = @metadata_store.document_hashes_for(metadata).filter_map do |document|
        next unless document.is_a?(Hash)

        explicit = normalize_rel(document["path"])
        unless explicit.empty?
          explicit
        else
          file = document["file"].to_s.strip
          next if file.empty?

          [@rel_path, file].reject(&:empty?).join("/")
        end
      end

      paths = from_metadata.uniq
      paths = fallback_text_paths if paths.empty?
      paths
    end
  end

  def fallback_text_paths
    return [] unless @abs_path.directory?

    Dir.children(@abs_path)
      .select { |name| name.downcase.end_with?(".txt") }
      .sort
      .map { |name| [@rel_path, name].reject(&:empty?).join("/") }
  end

  def normalize_rel(value)
    value.to_s.tr("\\", "/").sub(%r{\A/+}, "").sub(%r{/+\z}, "")
  end
end
