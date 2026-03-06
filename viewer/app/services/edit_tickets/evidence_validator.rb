module EditTickets
  class EvidenceValidator
    MAX_BYTES = 20.megabytes

    # Explicit allowlist.
    # NOTE: We intentionally do NOT allow svg/html/xhtml.
    ALLOWED_CONTENT_TYPES = %w[
      application/pdf
      text/plain
      image/png
      image/jpeg
    ].freeze

    # Map extensions to expected content types.
    EXTENSION_MAP = {
      ".pdf" => "application/pdf",
      ".txt" => "text/plain",
      ".patch" => "text/plain",
      ".diff" => "text/plain",
      ".png" => "image/png",
      ".jpg" => "image/jpeg",
      ".jpeg" => "image/jpeg"
    }.freeze

    DISALLOWED_DECLARED_TYPES = %w[text/html application/xhtml+xml image/svg+xml].freeze

    def self.validate!(uploaded)
      # uploaded is an ActionDispatch::Http::UploadedFile.
      raise ArgumentError, "missing upload" if uploaded.nil?

      if uploaded.size.to_i > MAX_BYTES
        raise ValidationError, "file too large (max #{MAX_BYTES / 1.megabyte} MB)"
      end

      filename = uploaded.original_filename.to_s
      ext = File.extname(filename).downcase
      expected = EXTENSION_MAP[ext]
      raise ValidationError, "file type not allowed" if expected.nil?

      declared = uploaded.content_type.to_s
      if DISALLOWED_DECLARED_TYPES.include?(declared)
        raise ValidationError, "file type not allowed"
      end

      # Trust-but-verify: sniff actual content.
      io = uploaded.tempfile
      sniffed = Marcel::MimeType.for(io, name: filename)
      io.rewind

      # Normalize some common values.
      sniffed = "text/plain" if sniffed == "text/x-diff"

      unless ALLOWED_CONTENT_TYPES.include?(sniffed)
        raise ValidationError, "file content type not allowed"
      end

      unless sniffed == expected
        raise ValidationError, "file content does not match its extension"
      end

      # Magic-byte sanity checks for common formats.
      validate_magic_bytes!(io, ext)
      io.rewind

      true
    end

    def self.validate_magic_bytes!(io, ext)
      head = io.read(16) || ""
      io.rewind

      case ext
      when ".pdf"
        raise ValidationError, "invalid PDF header" unless head.start_with?("%PDF-")
      when ".png"
        png_sig = "\x89PNG\r\n\x1A\n".b
        raise ValidationError, "invalid PNG header" unless head.b.start_with?(png_sig)
      when ".jpg", ".jpeg"
        # JPEG starts with FF D8 FF
        raise ValidationError, "invalid JPEG header" unless head.bytes[0, 3] == [0xFF, 0xD8, 0xFF]
      when ".txt", ".diff", ".patch"
        # Text: no strict magic bytes. We still reject obvious HTML starts.
        trimmed = head.lstrip
        if trimmed.start_with?("<html", "<!doctype", "<?xml")
          raise ValidationError, "HTML/XML uploads are not allowed"
        end
      end
    end

    class ValidationError < StandardError; end
  end
end
