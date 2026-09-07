# frozen_string_literal: true

require "yaml"

# Reads the RIME-style browser input schemas already configured for the site and
# keeps only schemas which actually have imported CharacterInputCode rows.
#
# Both Transcription Practice and the Word Processor use this service so they
# cannot silently drift into advertising different input methods.
class RimeSchemaRegistry
  class << self
    def available
      path = Rails.root.join("config", "rime_schemas.yml")
      return [] unless path.file?

      schemas = YAML.safe_load(File.open(path, "r:bom|utf-8", &:read), aliases: false).fetch("schemas", [])
      schema_ids = schemas.filter_map { |schema| schema["schema_id"].presence }

      available_ids = schema_ids.select do |schema_id|
        CharacterInputCode
          .where(system_id: schema_id)
          .where.not(kind: "auxiliary")
          .exists?
      end

      schemas
        .select { |schema| available_ids.include?(schema["schema_id"]) }
        .map { |schema| schema.merge("browser_available" => true) }
    rescue Psych::SyntaxError, KeyError
      []
    end
  end
end
