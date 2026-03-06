module EditTickets
  class UnifiedDiffValidator
    MAX_BYTES = 2.megabytes
    MAX_FILES = 50

    # Validates unified diffs intended for corpus text edits.
    # Rules:
    # - No path traversal (..), no absolute paths, no "a/../".
    # - No renames.
    # - Limit number of files.
    # - We only accept edits within a whitelist of roots (configured by caller).
    def self.validate!(diff_text, allowed_roots: [])
      raise ValidationError, "diff is empty" if diff_text.to_s.strip.empty?
      raise ValidationError, "diff too large" if diff_text.bytesize > MAX_BYTES

      if diff_text.include?("rename from") || diff_text.include?("rename to")
        raise ValidationError, "renames are not allowed"
      end

      files = extract_files(diff_text)
      raise ValidationError, "no files found in diff" if files.empty?
      raise ValidationError, "too many files (max #{MAX_FILES})" if files.size > MAX_FILES

      files.each do |path|
        validate_path!(path)
        if allowed_roots.any? && allowed_roots.none? { |root| path.start_with?(root) }
          raise ValidationError, "diff touches a disallowed path"
        end
      end

      {
        file_count: files.size,
        files: files
      }
    end

    def self.extract_files(diff_text)
      # Unified diff headers look like:
      # --- a/path/to/file
      # +++ b/path/to/file
      # We'll take the b/ path.
      files = []
      diff_text.each_line do |line|
        next unless line.start_with?("+++ ")
        raw = line.sub("+++ ", "").strip
        next if raw == "/dev/null"
        raw = raw.sub(/^b\//, "")
        files << raw
      end
      files.uniq
    end

    def self.validate_path!(path)
      raise ValidationError, "invalid path" if path.blank?
      raise ValidationError, "absolute paths not allowed" if path.start_with?("/", "\\")
      raise ValidationError, "path traversal not allowed" if path.split("/").include?("..")
      raise ValidationError, "nul byte not allowed" if path.include?("\0")
    end

    class ValidationError < StandardError; end
  end
end
