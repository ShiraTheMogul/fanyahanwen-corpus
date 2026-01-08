# frozen_string_literal: true

module PropertySources
  CONFIG_PATH = Rails.root.join("config", "property_sources.yml")

  def self.map
    @map ||= begin
      return {} unless File.exist?(CONFIG_PATH)
      YAML.safe_load(File.read(CONFIG_PATH)) || {}
    end
  end

  def self.url_for(source)
    entry = map[source.to_s]
    return nil unless entry.is_a?(Hash)
    url = entry["url"].to_s.strip
    url.empty? ? nil : url
  end
end
