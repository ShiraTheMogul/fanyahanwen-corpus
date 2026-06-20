module EditTickets
  class SubmissionExtras
    MAX_UPLOAD_FILES = 10
    MAX_TOTAL_UPLOAD_BYTES = 20.megabytes
    CONTACT_RETENTION = 30.days

    class ValidationError < StandardError; end

    def self.evidence_links(raw)
      value = parse_json_if_needed(raw)
      values = value.is_a?(String) ? value.lines : Array(value)

      values
        .flat_map { |item| item.to_s.lines }
        .map(&:strip)
        .reject(&:blank?)
        .uniq
    rescue JSON::ParserError
      raise ValidationError, "invalid JSON in evidence_links"
    end

    def self.contact_attributes(raw)
      value = parse_json_if_needed(raw)
      value = value.permit(:name, :email, :notes).to_h if value.respond_to?(:permit)
      value = value.to_h if value.respond_to?(:to_h)
      value = {} unless value.is_a?(Hash)

      attributes = {
        name: fetch(value, :name).to_s.strip,
        email: fetch(value, :email).to_s.strip,
        notes: fetch(value, :notes).to_s.strip
      }

      attributes.values.any?(&:present?) ? attributes : nil
    rescue JSON::ParserError
      raise ValidationError, "invalid JSON in contact"
    end

    def self.validate_uploads!(raw_uploads)
      uploads = Array(raw_uploads).compact

      if uploads.length > MAX_UPLOAD_FILES
        raise ValidationError, "too many evidence files (max #{MAX_UPLOAD_FILES})"
      end

      total_bytes = uploads.sum { |upload| upload.size.to_i }
      if total_bytes > MAX_TOTAL_UPLOAD_BYTES
        max_mb = MAX_TOTAL_UPLOAD_BYTES / 1.megabyte
        raise ValidationError, "evidence files are too large in total (max #{max_mb} MB)"
      end

      uploads.each { |upload| EditTickets::EvidenceValidator.validate!(upload) }
      uploads
    rescue EditTickets::EvidenceValidator::ValidationError => e
      raise ValidationError, e.message
    end

    def self.attach_uploads!(ticket, uploads)
      Array(uploads).each { |upload| ticket.evidence_files.attach(upload) }
    end

    def self.create_contact!(ticket, raw_contact)
      attributes = contact_attributes(raw_contact)
      return nil if attributes.nil?

      ticket.create_ticket_contact!(
        **attributes,
        expires_at: CONTACT_RETENTION.from_now
      )
    end

    def self.parse_json_if_needed(value)
      return JSON.parse(value) if value.is_a?(String) && value.strip.start_with?("[", "{")

      value
    end
    private_class_method :parse_json_if_needed

    def self.fetch(hash, key)
      hash[key] || hash[key.to_s]
    end
    private_class_method :fetch
  end
end
