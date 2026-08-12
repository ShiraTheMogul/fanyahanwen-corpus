# frozen_string_literal: true

require "set"

class CorpusFs
  DirectoryPage = Struct.new(:items, :page, :per_page, :raw_total, :total_pages, keyword_init: true)

  REPLACEMENT_CHARACTER = "\uFFFD"

  def initialize(root:, logger: default_logger)
    root = root.to_s
    raise ArgumentError, "Corpus root is empty" if root.strip.empty?
    @root = File.realpath(root)
    @logger = logger
    @warned_invalid_utf8_paths = Set.new
    @warning_mutex = Mutex.new
  end

  # Resolve a relative path into an absolute path under @root.
  # Always returns a String. Raises SecurityError if traversal is attempted.
  def resolve(rel)
    rel = (rel || "").to_s

    # Rails/servers often keep %2F encoded; treat it as a slash.
    rel = rel.gsub(/%2F/i, "/")

    # normalize separators + trim leading slashes
    rel = rel.tr("\\", "/").sub(%r{\A/+}, "")

    abs = File.expand_path(File.join(@root, rel))

    # Enforce that abs stays under @root
    root_prefix = @root.end_with?(File::SEPARATOR) ? @root : (@root + File::SEPARATOR)
    unless abs == @root || abs.start_with?(root_prefix)
      raise SecurityError, "Refusing path outside corpus root"
    end

    abs
  end

  # nil-safe checks (nil => false instead of crashing)
  def directory?(abs)
    abs.is_a?(String) && File.directory?(abs)
  end

  def file?(abs)
    abs.is_a?(String) && File.file?(abs)
  end

  # List only directories + .txt files.
  #
  # Keep the filesystem check to one stat per non-text entry. The old version
  # called File.directory? once while filtering and then again while
  # partitioning, which doubled the metadata I/O cost on very large folders.
  def list_dir(abs)
    return [] unless directory?(abs)

    dirs = []
    files = []

    Dir.each_child(abs) do |name|
      next if name.start_with?(".")

      if name.downcase.end_with?(".txt")
        files << name
      elsif File.directory?(File.join(abs, name))
        dirs << name
      end
    end

    dirs.sort!
    files.sort!
    dirs + files
  end

  # Large corpus directories should never stat tens of thousands of children
  # just to render one browser page. Pagination is based on the sorted raw
  # directory entries, then only the current slice is classified. This bounds
  # filesystem metadata calls to +per_page+ instead of the full directory size.
  def list_dir_page(abs, page:, per_page:)
    return DirectoryPage.new(items: [], page: 1, per_page: per_page, raw_total: 0, total_pages: 1) unless directory?(abs)

    page = [page.to_i, 1].max
    per_page = [[per_page.to_i, 1].max, 500].min
    entries = Dir.children(abs).reject { |name| name.start_with?(".") }.sort
    raw_total = entries.length
    total_pages = [(raw_total.to_f / per_page).ceil, 1].max
    page = [page, total_pages].min
    slice = entries.slice((page - 1) * per_page, per_page) || []

    items = slice.select do |name|
      name.downcase.end_with?(".txt") || File.directory?(File.join(abs, name))
    end

    DirectoryPage.new(
      items: items,
      page: page,
      per_page: per_page,
      raw_total: raw_total,
      total_pages: total_pages
    )
  end

  # Stop counting as soon as the threshold is crossed. Large directories only
  # pay for threshold + 1 names here; the paginated read below then performs the
  # one full name listing needed for sorting.
  def more_than_entries?(abs, threshold)
    return false unless directory?(abs)

    count = 0
    Dir.each_child(abs) do |name|
      next if name.start_with?(".")

      count += 1
      return true if count > threshold.to_i
    end
    false
  end

  def read_text(abs)
    raise Errno::ENOENT, "Not a file: #{abs.inspect}" unless file?(abs)

    text = File.binread(abs).force_encoding(Encoding::UTF_8)
    invalid_utf8 = !text.valid_encoding?
    text = text.scrub(REPLACEMENT_CHARACTER).sub(/\A\uFEFF/, "")

    warn_invalid_utf8(abs) if invalid_utf8
    text
  end

  private

  def warn_invalid_utf8(abs)
    first_warning = @warning_mutex.synchronize { @warned_invalid_utf8_paths.add?(abs) }
    return unless first_warning

    relative_path = abs.delete_prefix("#{@root}/")
    @logger&.warn(
      "[corpus_fs] malformed UTF-8 replaced with U+FFFD in #{relative_path}"
    )
  end

  def default_logger
    Rails.logger if defined?(Rails) && Rails.respond_to?(:logger)
  end
end
