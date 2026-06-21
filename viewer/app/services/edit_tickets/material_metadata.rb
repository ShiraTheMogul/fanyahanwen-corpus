# frozen_string_literal: true

require "json"

module EditTickets
  class MaterialMetadata
    PROVENANCE_TYPES = %w[user_made public_domain historical_source author_provided].freeze

    class ValidationError < StandardError; end

    def self.build!(params, require_note: true)
      note = params[:material_note].to_s.strip
      provenance = normalize_provenance(params[:provenance])
      references = params[:references].to_s.strip
      ai_assisted = truthy?(params[:ai_assisted])
      ai_details = params[:ai_details].to_s.strip

      raise ValidationError, "material note is required" if require_note && note.blank?
      raise ValidationError, "choose at least one provenance label" if provenance.empty?
      raise ValidationError, "describe the AI assistance" if ai_assisted && ai_details.blank?

      {
        "note" => note,
        "provenance" => provenance,
        "references" => references.presence,
        "ai_assisted" => ai_assisted,
        "ai_details" => ai_details.presence
      }.compact
    end

    def self.normalize_provenance(raw)
      value = raw
      value = JSON.parse(value) if value.is_a?(String) && value.strip.start_with?("[")

      Array(value)
        .flat_map { |item| item.to_s.split(",") }
        .map { |item| item.strip.downcase }
        .select { |item| PROVENANCE_TYPES.include?(item) }
        .uniq
    rescue JSON::ParserError
      raise ValidationError, "invalid provenance payload"
    end

    def self.truthy?(value)
      [true, 1, "1", "true", "yes", "on"].include?(value)
    end
  end
end
