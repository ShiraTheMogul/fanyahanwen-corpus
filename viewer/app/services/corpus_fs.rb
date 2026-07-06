# frozen_string_literal: true

require "set"

class CorpusFs
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

  # List only directories + .txt files
  def list_dir(abs)
    return [] unless directory?(abs)

    entries = Dir.children(abs)
    entries.reject! { |name| name.start_with?(".") }

    entries.select! do |name|
      full = File.join(abs, name)
      File.directory?(full) || name.downcase.end_with?(".txt")
    end

    dirs, files = entries.partition { |name| File.directory?(File.join(abs, name)) }
    (dirs.sort + files.sort)
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
