require "yaml"

module Textbook
  class ConversionProfile
    attr_reader :key, :label, :engine, :direction, :options

    def initialize(key:, label:, engine:, direction:, options: {})
      @key = key.to_s
      @label = label.to_s
      @engine = engine.to_s
      @direction = direction.to_s
      @options = options || {}
    end
  end

  class ConversionProfiles
    BASE_DIR = Rails.root.join("config", "textbook", "conversions")

    class << self
      def list
        @list ||= load_all
      end

      def fetch(key)
        k = key.to_s
        prof = list.find { |p| p.key == k }
        raise ArgumentError, "Unknown conversion profile: #{k}" unless prof
        prof
      end

      def reload!
        @list = load_all
      end

      private

      def load_all
        profiles = []
        Dir.glob(BASE_DIR.join("*.yml")).sort.each do |path|
          data = YAML.safe_load(File.read(path, encoding: "utf-8"), permitted_classes: [], permitted_symbols: [], aliases: false) || {}
          Array(data["profiles"]).each do |h|
            next unless h.is_a?(Hash)
            profiles << ConversionProfile.new(
              key: h["key"],
              label: h["label"] || h["key"],
              engine: h["engine"],
              direction: h["direction"],
              options: h["options"] || {}
            )
          end
        end
        profiles
      end
    end
  end
end
